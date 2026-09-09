// Apple's on-device Foundation Model, exposed to the Mac Bridge as a one-shot CLI.
//
// This is the tool a cloud agent cannot get anywhere else: inference that is free, private, offline,
// and never leaves the machine. The bridge compiles this once into a cache directory and then
// execs the binary, so per-call cost is process startup rather than a Swift compile.
import Foundation
import FoundationModels

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: on-device <prompt>".utf8))
    exit(64)
}

let model = SystemLanguageModel.default
guard model.availability == .available else {
    // A specific, actionable reason beats a generic failure: Apple Intelligence may simply be off.
    FileHandle.standardError.write(Data("The on-device model is unavailable: \(model.availability)".utf8))
    exit(69)
}

do {
    let session = LanguageModelSession()
    let reply = try await session.respond(to: arguments[1])
    print(reply.content)
} catch {
    FileHandle.standardError.write(Data("On-device generation failed: \(error)".utf8))
    exit(70)
}
