mod clock;
mod cli;
mod data_root;
mod delegate;
mod error;
mod feature_use;
mod front_edit;
mod git;
mod hook;
mod note;
mod project_config;
mod project_map;
mod ruby_text;
mod session_log;
mod session_rows;
mod work_item;
mod yaml_scalar;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(cli::run(args));
}
