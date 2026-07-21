#![forbid(unsafe_code)]

fn main() {
    let code = std::env::args()
        .nth(1)
        .expect("exit code argument is required")
        .parse::<i32>()
        .expect("exit code must be an integer");
    std::process::exit(code);
}
