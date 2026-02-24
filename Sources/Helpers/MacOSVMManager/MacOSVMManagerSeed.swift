import Foundation

func runProcess(executablePath: String, arguments: [String]) throws {
    let process = Process()
    if executablePath.contains("/") {
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executablePath] + arguments
    }
    process.environment = ProcessInfo.processInfo.environment
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    if process.terminationReason != .exit || process.terminationStatus != 0 {
        throw ArgumentError.required("process failed: \(executablePath) \(arguments.joined(separator: " "))")
    }
}

func copyFileReplacing(from: URL, to: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: to.path) {
        try fm.removeItem(at: to)
    }
    try fm.copyItem(at: from, to: to)
}

func setPermissions(_ mode: Int, url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

func prepareSeedDirectory(
    seedDir: URL,
    guestAgentBinOverride: String?,
    seedScriptsDirOverride: String?
) throws {
    let fm = FileManager.default

    let cwd = URL(fileURLWithPath: fm.currentDirectoryPath).standardizedFileURL

    let guestAgentCandidates: [URL] = {
        var values: [URL] = []
        if let guestAgentBinOverride, !guestAgentBinOverride.isEmpty {
            values.append(URL(fileURLWithPath: guestAgentBinOverride, relativeTo: cwd).absoluteURL.standardizedFileURL)
        }
        if let v = ProcessInfo.processInfo.environment["CONTAINER_MACOS_GUEST_AGENT_BIN"], !v.isEmpty {
            values.append(URL(fileURLWithPath: v, relativeTo: cwd).absoluteURL.standardizedFileURL)
        }
        if let v = ProcessInfo.processInfo.environment["GUEST_AGENT_BIN"], !v.isEmpty {
            values.append(URL(fileURLWithPath: v, relativeTo: cwd).absoluteURL.standardizedFileURL)
        }
        values.append(URL(fileURLWithPath: "/usr/local/libexec/container/macos-guest-agent/bin/container-macos-guest-agent"))
        values.append(cwd.appendingPathComponent(".build/release/container-macos-guest-agent"))
        values.append(cwd.appendingPathComponent(".build/debug/container-macos-guest-agent"))
        values.append(cwd.appendingPathComponent(".build/arm64-apple-macosx/release/container-macos-guest-agent"))
        values.append(cwd.appendingPathComponent(".build/arm64-apple-macosx/debug/container-macos-guest-agent"))
        return values
    }()

    let guestAgentURL = guestAgentCandidates.first(where: { fm.isExecutableFile(atPath: $0.path) })
    guard let guestAgentURL else {
        throw ArgumentError.required("guest agent binary not found; use --guest-agent-bin or set CONTAINER_MACOS_GUEST_AGENT_BIN")
    }

    let scriptsDirCandidates: [URL] = {
        var values: [URL] = []
        if let seedScriptsDirOverride, !seedScriptsDirOverride.isEmpty {
            values.append(URL(fileURLWithPath: seedScriptsDirOverride, relativeTo: cwd).absoluteURL.standardizedFileURL)
        }
        if let v = ProcessInfo.processInfo.environment["CONTAINER_MACOS_GUEST_AGENT_SCRIPTS_DIR"], !v.isEmpty {
            values.append(URL(fileURLWithPath: v, relativeTo: cwd).absoluteURL.standardizedFileURL)
        }
        values.append(URL(fileURLWithPath: "/usr/local/libexec/container/macos-guest-agent/share"))
        values.append(cwd.appendingPathComponent("scripts/macos-guest-agent"))
        return values
    }()

    let scriptsDirURL = scriptsDirCandidates.first(where: { path in
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: path.path, isDirectory: &isDirectory) && isDirectory.boolValue
    })
    guard let scriptsDirURL else {
        throw ArgumentError.required("guest agent scripts directory not found; use --seed-scripts-dir or set CONTAINER_MACOS_GUEST_AGENT_SCRIPTS_DIR")
    }

    let installScript = scriptsDirURL.appendingPathComponent("install.sh")
    let plistTemplate = scriptsDirURL.appendingPathComponent("container-macos-guest-agent.plist")
    let installFromSeedScript = scriptsDirURL.appendingPathComponent("install-in-guest-from-seed.sh")
    for required in [installScript, plistTemplate, installFromSeedScript] {
        guard fm.fileExists(atPath: required.path) else {
            throw ArgumentError.required("missing required seed file: \(required.path)")
        }
    }

    if fm.fileExists(atPath: seedDir.path) {
        try fm.removeItem(at: seedDir)
    }
    try fm.createDirectory(at: seedDir, withIntermediateDirectories: true)

    let agentDest = seedDir.appendingPathComponent("container-macos-guest-agent")
    let installDest = seedDir.appendingPathComponent("install.sh")
    let plistDest = seedDir.appendingPathComponent("container-macos-guest-agent.plist")
    let installFromSeedDest = seedDir.appendingPathComponent("install-in-guest-from-seed.sh")

    try copyFileReplacing(from: guestAgentURL, to: agentDest)
    try copyFileReplacing(from: installScript, to: installDest)
    try copyFileReplacing(from: plistTemplate, to: plistDest)
    try copyFileReplacing(from: installFromSeedScript, to: installFromSeedDest)

    try setPermissions(0o755, url: agentDest)
    try setPermissions(0o755, url: installDest)
    try setPermissions(0o644, url: plistDest)
    try setPermissions(0o755, url: installFromSeedDest)
}
