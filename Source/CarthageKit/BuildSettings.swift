import Foundation
import Result
import ReactiveTask
import ReactiveSwift
import XCDBLD

/// A map of build settings and their values, as generated by Xcode.
public struct BuildSettings {
	/// The target to which these settings apply.
	public let target: String

	/// All build settings given at initialization.
	public let settings: [String: String]

	/// The build arguments used for loading the settings.
	public let arguments: BuildArguments

	/// The designated xcodebuild action if present.
	public let action: BuildArguments.Action?

	internal init(
		target: String,
		settings: [String: String],
		arguments: BuildArguments,
		action: BuildArguments.Action?
	) {
		self.target = target
		self.settings = settings
		self.arguments = arguments
		self.action = action
	}

	/// Matches lines of the forms:
	///
	/// Build settings for action build and target "ReactiveCocoaLayout Mac":
	/// Build settings for action test and target CarthageKitTests:
	private static let targetSettingsRegex = try! NSRegularExpression( // swiftlint:disable:this force_try
		pattern: "^Build settings for action (?:\\S+) and target \\\"?([^\":]+)\\\"?:$",
		options: [ .caseInsensitive, .anchorsMatchLines ]
	)

	/// Invokes `xcodebuild` to retrieve build settings for the given build
	/// arguments.
	///
	/// Upon .success, sends one BuildSettings value for each target included in
	/// the referenced scheme.
	public static func load(with arguments: BuildArguments, for action: BuildArguments.Action? = nil, with environment: [String: String]? = nil) -> SignalProducer<BuildSettings, CarthageError> {
		// xcodebuild (in Xcode 8.0) has a bug where xcodebuild -showBuildSettings
		// can hang indefinitely on projects that contain core data models.
		// rdar://27052195
		// Including the action "clean" works around this issue, which is further
		// discussed here: https://forums.developer.apple.com/thread/50372
		//
		// "archive" also works around the issue above so use it to determine if
		// it is configured for the archive action.
		let task = xcodebuildTask(["archive", "-showBuildSettings", "-skipUnavailableActions"], arguments, environment: environment)

		return task.launch()
			.ignoreTaskData()
			.mapError(CarthageError.taskError)
			// xcodebuild has a bug where xcodebuild -showBuildSettings
			// can sometimes hang indefinitely on projects that don't
			// share any schemes, so automatically bail out if it looks
			// like that's happening.
			.timeout(after: 600, raising: .xcodebuildTimeout(arguments.project), on: QueueScheduler(qos: .default))
			.retry(upTo: 5)
			.map { data in
				return String(data: data, encoding: .utf8)!
			}
			.flatMap(.merge) { string -> SignalProducer<BuildSettings, CarthageError> in
				return SignalProducer { observer, lifetime in
					var currentSettings: [String: String] = [:]
					var currentTarget: String?

					let flushTarget = { () -> Void in
						if let currentTarget = currentTarget {
							let buildSettings = self.init(
								target: currentTarget,
								settings: currentSettings,
								arguments: arguments,
								action: action
							)
							observer.send(value: buildSettings)
						}

						currentTarget = nil
						currentSettings = [:]
					}

					string.enumerateLines { line, stop in
						if lifetime.hasEnded {
							stop = true
							return
						}

						if let result = self.targetSettingsRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
							let targetRange = Range(result.range(at: 1), in: line)!

							flushTarget()
							currentTarget = String(line[targetRange])
							return
						}

						let trimSet = CharacterSet.whitespacesAndNewlines
						let components = line
							.split(maxSplits: 1) { $0 == "=" }
							.map { $0.trimmingCharacters(in: trimSet) }

						if components.count == 2 {
							currentSettings[components[0]] = components[1]
						}
					}

					flushTarget()
					observer.sendCompleted()
				}
			}
	}

	/// Determines which SDKs the given scheme builds for, by default.
	///
	/// If an SDK is unrecognized or could not be determined, an error will be
	/// sent on the returned signal.
	public static func SDKsForScheme(_ scheme: Scheme, inProject project: ProjectLocator) -> SignalProducer<SDK, CarthageError> {
		return load(with: BuildArguments(project: project, scheme: scheme))
			.zip(with: SDK.setsFromJSONShowSDKsWithFallbacks.promoteError(CarthageError.self))
			.take(first: 1)
			.map { $1.intersection($0.buildSDKRawNames.map { sdk in SDK(name: sdk, simulatorHeuristic: "") }) }
			.flatten()
	}

	/// Returns the value for the given build setting, or an error if it could
	/// not be determined.
	public subscript(key: String) -> Result<String, CarthageError> {
		if let value = settings[key] {
			return .success(value)
		} else {
			return .failure(.missingBuildSetting(key))
		}
	}

	/// Attempts to determine the SDKs this scheme builds for.
	public var buildSDKRawNames: Set<String> {
		let supportedPlatforms = self["SUPPORTED_PLATFORMS"]

		if let supportedPlatforms = supportedPlatforms.value {
			return Set(
				supportedPlatforms.split(separator: " ").map(String.init)
			)
		} else if let platformName = self["PLATFORM_NAME"].value {
			return [platformName] as Set
		} else {
			return [] as Set
		}
	}

	public var archs: Result<Set<String>, CarthageError> {
		return self["ARCHS"].map { Set($0.components(separatedBy: " ")) }
	}

	/// Attempts to determine the ProductType specified in these build settings.
	public var productType: Result<ProductType, CarthageError> {
		return self["PRODUCT_TYPE"].flatMap(ProductType.from(string:))
	}

	/// Attempts to determine the MachOType specified in these build settings.
	public var machOType: Result<MachOType, CarthageError> {
		return self["MACH_O_TYPE"].flatMap(MachOType.from(string:))
	}

	/// Attempts to determine the FrameworkType identified by these build settings.
	internal var frameworkType: Result<FrameworkType?, CarthageError> {
		return productType.fanout(machOType).map(FrameworkType.init)
	}

	internal var frameworkSearchPaths: Result<[URL], CarthageError> {
		return self["FRAMEWORK_SEARCH_PATHS"].map { paths in
			paths.split(separator: " ").map { URL(fileURLWithPath: String($0), isDirectory: true) }
		}
	}

	/// Attempts to determine the URL to the built products directory.
	public var builtProductsDirectoryURL: Result<URL, CarthageError> {
		return self["BUILT_PRODUCTS_DIR"].map { productsDir in
			return URL(fileURLWithPath: productsDir, isDirectory: true)
		}
	}

	private var productsDirectoryURLDependingOnAction: Result<URL, CarthageError> {
		if action == .archive {
			return self["OBJROOT"]
				.fanout(archiveIntermediatesBuildProductsPath)
				.map { objroot, path -> URL in
					let root = URL(fileURLWithPath: objroot, isDirectory: true)
					return root.appendingPathComponent(path)
				}
		} else {
			return builtProductsDirectoryURL
		}
	}

	private var archiveIntermediatesBuildProductsPath: Result<String, CarthageError> {
		let r1 = self["TARGET_NAME"]
		guard let schemeOrTarget = arguments.scheme?.name ?? r1.value else { return r1 }

		let basePath = "ArchiveIntermediates/\(schemeOrTarget)/BuildProductsPath"
		let pathComponent: String

		if
			let buildDir = self["BUILD_DIR"].value,
			let builtProductsDir = self["BUILT_PRODUCTS_DIR"].value,
			builtProductsDir.hasPrefix(buildDir)
		{
			// This is required to support CocoaPods-generated projects.
			// See https://github.com/AliSoftware/Reusable/issues/50#issuecomment-336434345 for the details.
			pathComponent = String(builtProductsDir[buildDir.endIndex...]) // e.g., /Release-iphoneos/Reusable-iOS
		} else {
			let r2 = self["CONFIGURATION"]
			guard let configuration = r2.value else { return r2 }

			// A value almost certainly beginning with `-` or (lacking said value) an
			// empty string to append without effect in the path below because Xcode
			// expects the path like that.
			let effectivePlatformName = self["EFFECTIVE_PLATFORM_NAME"].value ?? ""

			// e.g.,
			// - Release
			// - Release-iphoneos
			pathComponent = "\(configuration)\(effectivePlatformName)"
		}

		let path = (basePath as NSString).appendingPathComponent(pathComponent)
		return .success(path)
	}

	/// Attempts to determine the relative path (from the build folder) to the
	/// built executable.
	public var executablePath: Result<String, CarthageError> {
		return self["EXECUTABLE_PATH"]
	}

	/// Attempts to determine the URL to the built executable, corresponding to
	/// its xcodebuild action.
	public var executableURL: Result<URL, CarthageError> {
		return productsDirectoryURLDependingOnAction
			.fanout(executablePath)
			.map { productsDirectoryURL, executablePath in
				return productsDirectoryURL.appendingPathComponent(executablePath)
			}
	}

	/// Attempts to determine the name of the built product's wrapper bundle.
	public var wrapperName: Result<String, CarthageError> {
		return self["WRAPPER_NAME"]
	}

	/// Attempts to determine the name of the built product.
	public var productName: Result<String, CarthageError> {
		return self["PRODUCT_NAME"]
	}

	/// Attempts to determine the URL to the built product's wrapper, corresponding
	/// to its xcodebuild action.
	public var wrapperURL: Result<URL, CarthageError> {
		return productsDirectoryURLDependingOnAction
			.fanout(wrapperName)
			.map { productsDirectoryURL, wrapperName in
				return productsDirectoryURL.appendingPathComponent(wrapperName)
			}
	}

	/// Attempts to determine whether bitcode is enabled or not.
	public var bitcodeEnabled: Result<Bool, CarthageError> {
		return self["ENABLE_BITCODE"].map { $0 == "YES" }
	}

	/// Attempts to determine the relative path (from the build folder) where
	/// the Swift modules for the built product will exist.
	///
	/// If the product does not build any modules, `nil` will be returned.
	internal var relativeModulesPath: Result<String?, CarthageError> {
		if let moduleName = self["PRODUCT_MODULE_NAME"].value {
			return self["CONTENTS_FOLDER_PATH"].map { contentsPath in
				let path1 = (contentsPath as NSString).appendingPathComponent("Modules")
				let path2 = (path1 as NSString).appendingPathComponent(moduleName)
				return (path2 as NSString).appendingPathExtension("swiftmodule")
			}
		} else {
			return .success(nil)
		}
	}

	/// Attempts to determine the code signing identity.
	public var codeSigningIdentity: Result<String, CarthageError> {
		return self["CODE_SIGN_IDENTITY"]
	}

	/// Attempts to determine if ad hoc code signing is allowed.
	public var adHocCodeSigningAllowed: Result<Bool, CarthageError> {
		return self["AD_HOC_CODE_SIGNING_ALLOWED"].map { $0 == "YES" }
	}

	/// Attempts to determine the path to the project that contains the current target
	public var projectPath: Result<String, CarthageError> {
		return self["PROJECT_FILE_PATH"]
	}

	/// Attempts to determine target build directory
	public var targetBuildDirectory: Result<String, CarthageError> {
		return self["TARGET_BUILD_DIR"]
	}

	/// The "OPERATING_SYSTEM" component of the target triple. Used in XCFrameworks to denote the supported platform.
	public var platformTripleOS: Result<String, CarthageError> {
		return self["LLVM_TARGET_TRIPLE_OS_VERSION"].map { osVersion in
			// osVersion is a string like "ios8.0". Remove any trailing version number.
			// This should match the OS component of an "unversionedTriple" printed by `swift -print-target-info`.
			osVersion.replacingOccurrences(of: "([0-9]\\.?)*$", with: "", options: .regularExpression)
		}.flatMapError { _ in
			// LLVM_TARGET_TRIPLE_OS_VERSION may be unavailable if `USE_LLVM_TARGET_TRIPLES = NO`.
			// SWIFT_PLATFORM_TARGET_PREFIX anecdotally appears to contain the unversioned OS component, even in
			// non-swift projects.
			self["SWIFT_PLATFORM_TARGET_PREFIX"]
		}
	}

	// The "ENVIRONMENT" component of the target triple, which is "simulator" when building for a simulator target
	// and missing otherwise.
	public var platformTripleVariant: Result<String, CarthageError> {
		return self["LLVM_TARGET_TRIPLE_SUFFIX"].map { $0.stripping(prefix: "-") }
	}

	/// Add subdirectory path if it's not possible to paste product to destination path
	public func productDestinationPath(in destinationURL: URL) -> URL {
		let directoryURL: URL
		let frameworkType = self.frameworkType.value.flatMap { $0 }
		if frameworkType == .static {
			directoryURL = destinationURL.appendingPathComponent(FrameworkType.staticFolderName)
		} else {
			directoryURL = destinationURL
		}
		return directoryURL
	}
}

extension BuildSettings: CustomStringConvertible {
	public var description: String {
		return "Build settings for target \"\(target)\": \(settings)"
	}
}

private enum Environment {
	static let withoutActiveXcodeXCConfigFile: [String: String] =
		ProcessInfo.processInfo.environment
			.merging(
				["XCODE_XCCONFIG_FILE": "/dev/null", "LC_ALL": "c"],
				 uniquingKeysWith: { _, replacer in replacer }
			)
}

extension SDK {
	/// Starting around Xcode 7.3.1, and current as of Xcode 11.5, Xcodes contain a
	/// xcodeproj that we can derive `XCDBLD.SDK`s via Xcode-defaulted `AVAILABLE_PLATFORMS`.
	///
	/// - Note: Pass no scheme, later Xcodes handle it correctly, but Xcode 7.3.1 doesn’t…
	/// - Note: As last ditch effort, try inside `/Applications/Xcode.app`, which might not exist.
	/// - Note: Mostly, `xcodebuild -showsdks -json`-based `XCDBLD.SDK`s will be grabbed instead of
	///         this signal reaching completion.
	/// - Note: Will, where possible, draw from `SDK.knownIn2019YearSDKs` for 2019-era captialization.
	static let setFromFallbackXcodeprojBuildSettings: SignalProducer<Set<SDK>?, NoError> =
		Task("/usr/bin/xcrun", arguments: ["--find", "xcodebuild"], environment: Environment.withoutActiveXcodeXCConfigFile)
			.launch()
			.materializeResults() // to map below and ignore errors
			.map {
				$0.value?.value.flatMap { String(data: $0, encoding: .utf8) }
					?? "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild\n"
			}
			.map { String.reversed($0)().first == "\n" ? String($0.dropLast(1)) : $0 }
			.map(URL.init(fileURLWithPath:))
			.map { (base: URL) in
				let relative = "../../usr/share/xcs/xcsd/node_modules/nodobjc/node_modules/ffi/deps/libffi/libffi.xcodeproj/"
				return relative.withCString {
					URL(fileURLWithFileSystemRepresentation: $0, isDirectory: true, relativeTo: base.isFileURL ? base.standardizedFileURL : URL(string: "file:///var/empty/ø/ø/ø/")!)
				}
			}
			.map { (potentialFile: URL) in BuildArguments(
				project: ProjectLocator.projectFile(potentialFile),
				scheme: Scheme?.none,
				configuration: "Release"
			) }
			.map { ($0 as BuildArguments, BuildArguments.Action?.none, Environment.withoutActiveXcodeXCConfigFile) }
			.flatMap(.race, BuildSettings.load) // note: above var empty path will soft error and get nilled below
			.materializeResults()
			.reduce(into: Set<SDK>?.none) {
				guard let unsplit = $1.value?.settings["AVAILABLE_PLATFORMS"] else { return }
				guard $0 == nil else { return }
				$0 = Set(
					unsplit.split(separator: " ").lazy.map {
						SDK(rawValue: String($0)) ?? SDK(name: String($0), simulatorHeuristic: "")
					}
				)
			}
}

extension SDK {
	/// - See: `SDK.setFromJSONShowSDKs`
	/// - Note: Fallbacks are `SDK.setFromFallbackXcodeprojBuildSettings` and
	///         hardcoded `SDK.knownIn2019YearSDKs`.
	static let setsFromJSONShowSDKsWithFallbacks: SignalProducer<Set<SDK>, NoError> =
		SDK.setFromJSONShowSDKs
			.concat(SDK.setFromFallbackXcodeprojBuildSettings)
			.skip(while: { $0 == nil })
			.take(first: 1)
			.skipNil()
			.reduce(into: SDK.knownIn2019YearSDKs) { $0 = $1 }
			.replayLazily(upTo: 1)
}
