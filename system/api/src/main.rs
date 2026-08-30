use std::{env, io, process::ExitCode};

use flashos_system::{ProductionProvider, transport};

fn main() -> ExitCode {
    let arguments = env::args_os().skip(1).collect::<Vec<_>>();
    let response = transport::execute(&arguments, &ProductionProvider);
    if io::Write::write_all(&mut io::stdout().lock(), &response.stdout).is_err() {
        transport::write_transport_diagnostic(io::stderr().lock());
        return ExitCode::from(2);
    }
    ExitCode::from(response.exit_code)
}
