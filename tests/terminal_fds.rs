//! The terminal bridge's pseudo-terminal fds must not leak into child processes the server spawns.

use quartermaster::terminal_bridge::open_pty;
use std::os::fd::AsRawFd;

#[test]
fn both_ends_of_a_pty_are_close_on_exec() {
    let (master, slave) = open_pty(80, 24).expect("a pty");
    for (name, fd) in [("master", master.as_raw_fd()), ("slave", slave.as_raw_fd())] {
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
        assert!(flags >= 0 && flags & libc::FD_CLOEXEC != 0, "{name} fd {fd} has flags {flags}");
    }
}
