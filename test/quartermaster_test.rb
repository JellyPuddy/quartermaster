# frozen_string_literal: true

# The whole suite: `ruby test/quartermaster_test.rb`. Each file runs as its own fresh process,
# QM_TEST_JOBS at once (default: the CPU count); QM_TEST_JOBS=1 runs them all in this process.
# Files that require test_helper also run alone. A new test file goes in this list.
SUITE_FILES = %w[
  work_item_test
  automation_items_test
  automation_chat_test
  item_deletion_test
  hook_test
  free_text_args_test
  failure_log_test
  error_log_test
  file_version_test
  viewer_test
  attention_test
  run_attention_test
  launcher_test
  run_session_resume_test
  ruby_pin_test
  doctor_test
  gui_test
  link_opener_test
  gui_handoff_test
  gui_benchmark_test
  distill_test
  board_mirror_test
  gh_stack_test
  worktrees_test
  cleanup_test
  pf_test
  project_config_test
  config_file_test
  config_cli_test
  gui_settings_test
  gui_automations_test
  config_reads_test
  routines_client_test
  automation_store_test
  run_log_test
  automation_cli_test
  chat_attention_test
  chat_pane_test
  aside_test
  loose_chat_test
  history_rotation_test
  finish_test
  usage_test
  caffeinate_test
  prs_view_test
  pr_review_start_test
  automation_flows_test
  automation_tick_test
  automation_run_lifecycle_test
  quiet_runs_test
  pr_prerequisites_test
  pr_deployment_test
  statusline_test
  rate_limits_test
  transcript_search_test
  non_object_lines_test
  overview_test
  turn_notifier_test
  diff_pane_test
  branch_stats_test
  benchmark_report_test
  benchmark_run_test
  pr_scope_test
  pr_threads_test
  page_annotations_test
  drafts_test
  feature_use_test
  pr_drafts_test
  chat_review_drafts_test
  pr_post_test
  pr_submit_test
  clipboard_annotations_test
  issue_drafts_test
  issue_start_test
  epic_sub_issues_test
  issue_links_test
  issue_comments_test
  issue_cleanup_test
  prompt_snapshots_test
  prompt_diff_test
  build_progress_test
  restack_test
  showcase_demo_world_test
  showcase_video_test
  showcase_shots_test
  showcase_demo_data_test
  local_schedule_test
  local_cron_test
  tick_installer_test
  local_automation_cli_test
  todo_list_test
  gui_todos_test
  gui_epic_test
  gui_globals_test
  docs_shape_test
  size_ratchet_test
  parallel_suite_test
].map { |name| File.join(__dir__, "#{name}.rb") }.freeze

require_relative "parallel_suite"
jobs = ParallelSuite.jobs
if jobs == 1
  require_relative "test_helper"
  SUITE_FILES.each { |file| require file }
else
  seed, args = ParallelSuite.split_seed(ARGV)
  exit ParallelSuite.new(SUITE_FILES, jobs: jobs, seed: seed, args: args).run
end
