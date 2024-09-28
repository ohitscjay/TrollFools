import Foundation

class DebDecomposer {
    private var composeBinaryURL: URL = {
        if #available(iOS 16.0, *) {
            return Bundle.main.url(forResource: "composedeb", withExtension: nil)!
        } else {
            return Bundle.main.url(forResource: "composedeb-15", withExtension: nil)!
        }
    }()

    func decomposeDeb(at sourceURL: URL, to destinationURL: URL) -> URL? {
        let composedebPath = Bundle.main.url(forResource: "composedeb", withExtension: nil)!.path
        let executablePath = (composedebPath as NSString).deletingLastPathComponent
        
        let environment = [
            "PATH": "\(executablePath):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
        ]
        
        let logFilePath = destinationURL.appendingPathComponent("decomposeDeb.log").path
        let logFileHandle: FileHandle?

        if FileManager.default.fileExists(atPath: logFilePath) {
            logFileHandle = FileHandle(forWritingAtPath: logFilePath)
            logFileHandle?.seekToEndOfFile()
        } else {
            FileManager.default.createFile(atPath: logFilePath, contents: nil, attributes: nil)
            logFileHandle = FileHandle(forWritingAtPath: logFilePath)
        }

        guard let logHandle = logFileHandle else {
            print("Failed to create log file handle")
            return nil
        }

        func log(_ message: String) {
            if let data = (message + "\n").data(using: .utf8) {
                logHandle.write(data)
            }
        }

        log("Starting decomposeDeb for file \(sourceURL.lastPathComponent)")
        log("Using composedeb at path \(composedebPath)")
        log("Executable path: \(executablePath)")

        do {
            let randomDirectoryName = UUID().uuidString
            let randomDirectoryURL = destinationURL.appendingPathComponent(randomDirectoryName)
            try FileManager.default.createDirectory(at: randomDirectoryURL, withIntermediateDirectories: true, attributes: nil)

            let receipt = try Execute.rootSpawnWithOutputs(binary: composeBinaryURL.path, arguments: [
                sourceURL.path,
                randomDirectoryURL.path,
                Bundle.main.bundlePath,
            ], environment: environment)

            guard case .exit(let code) = receipt.terminationReason, code == 0 else {
                let errorMessage = "Command failed with reason: \(receipt.terminationReason) and status: \(receipt.terminationReason)"
                log(errorMessage)
                log("Standard Error: \(receipt.stderr)")
                return nil
            }

            log("Command Output: \(receipt.stdout)")
            log("Standard Error: \(receipt.stderr)")
            log("Decompose Deb File \(sourceURL.lastPathComponent) done")

            let fileManager = FileManager.default
            let enumerator = fileManager.enumerator(at: randomDirectoryURL, includingPropertiesForKeys: nil)

            while let file = enumerator?.nextObject() as? URL {
                if file.pathExtension.lowercased() == "dylib" {
                    log("Found dylib: \(file.path)")
                    return file
                }
            }

            log("No .dylib files found in the decomposed contents.")
            return nil

        } catch {
            log("Error occurred: \(error.localizedDescription)")
            return nil
        }
    }
}
