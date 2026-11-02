import Darwin
import Foundation

/// Unlike Foundation.Process on macOS, owned children keep the caller's
/// process group. The Python check runner can then cancel the entire workload
/// session, including version probes, rather than orphaning a worker.
enum BenchmarkProcess {
  static func run(
    executable: String, arguments: [String], captureOutput: Bool = false
  ) throws -> Data {
    var argv = ([executable] + arguments).map { strdup($0) } + [nil]
    var environment =
      ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
      + [nil]
    defer {
      for pointer in argv { free(pointer) }
      for pointer in environment { free(pointer) }
    }
    guard argv.dropLast().allSatisfy({ $0 != nil }),
      environment.dropLast().allSatisfy({ $0 != nil })
    else { throw BenchmarkFailure("process_arguments") }

    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else {
      throw BenchmarkFailure("process_attributes")
    }
    defer { posix_spawnattr_destroy(&attributes) }
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
      posix_spawnattr_setpgroup(&attributes, getpgrp()) == 0
    else { throw BenchmarkFailure("process_group") }

    let output = captureOutput ? Pipe() : nil
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
      throw BenchmarkFailure("process_files")
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard
      posix_spawn_file_actions_addopen(
        &actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0
    else { throw BenchmarkFailure("process_files") }
    let stdoutAction: Int32
    if let output {
      stdoutAction = posix_spawn_file_actions_adddup2(
        &actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    } else {
      stdoutAction = posix_spawn_file_actions_addopen(
        &actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    }
    let stderrAction =
      captureOutput
      ? posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
      : posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDERR_FILENO)
    guard stdoutAction == 0, stderrAction == 0 else { throw BenchmarkFailure("process_files") }

    var pid: pid_t = 0
    let spawned = argv.withUnsafeMutableBufferPointer { arguments in
      environment.withUnsafeMutableBufferPointer { environment in
        posix_spawn(
          &pid, executable, &actions, &attributes, arguments.baseAddress!, environment.baseAddress!)
      }
    }
    guard spawned == 0 else { throw BenchmarkFailure("process_spawn") }
    var reaped = false
    defer {
      if !reaped {
        // The PID remains ours until waitpid reaps it, so cleanup cannot
        // accidentally signal a later process that reused the number.
        kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
      }
    }
    try output?.fileHandleForWriting.close()
    let data = output?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    try output?.fileHandleForReading.close()
    var status: Int32 = 0
    while true {
      if waitpid(pid, &status, 0) == pid { break }
      guard errno == EINTR else { throw BenchmarkFailure("process_wait") }
    }
    reaped = true
    guard status == 0 else { throw BenchmarkFailure("process_exit") }
    return data
  }
}
