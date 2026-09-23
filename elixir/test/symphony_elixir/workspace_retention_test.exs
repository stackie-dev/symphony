defmodule SymphonyElixir.WorkspaceRetentionTest do
  use SymphonyElixir.TestSupport

  test "removes a clean verified checkout after its before_remove hook succeeds" do
    root = new_root("clean")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "STA-CLEAN")
    hook_marker = Path.join(root, "before-remove-ran")
    File.mkdir_p!(workspace_root)
    SymphonyElixir.WorkspaceGitSupport.clean_checkout!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_before_remove: "touch #{hook_marker}"
    )

    assert {:ok, []} = Workspace.remove(workspace)
    assert File.exists?(hook_marker)
    refute File.exists?(workspace)
  end

  test "retains tracked changes, untracked files, and commits not present on remotes" do
    root = new_root("unique-work")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "STA-UNIQUE")
    File.mkdir_p!(workspace_root)
    SymphonyElixir.WorkspaceGitSupport.clean_checkout!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    File.write!(Path.join(workspace, "README.md"), "tracked changes\n")
    File.write!(Path.join(workspace, "local-notes.txt"), "untracked work\n")

    assert {:error, {{:workspace_retained, "retained:working_tree_changes"}, _output}, ""} =
             Workspace.remove(workspace)

    assert File.read!(Path.join(workspace, "README.md")) == "tracked changes\n"
    assert File.read!(Path.join(workspace, "local-notes.txt")) == "untracked work\n"

    File.write!(Path.join(workspace, "README.md"), "committed locally\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "local only work"])

    assert {:error, {{:workspace_retained, "retained:unique_commits"}, _output}, ""} =
             Workspace.remove(workspace)

    assert File.dir?(workspace)
  end

  test "retains the workspace when before_remove fails" do
    root = new_root("hook-failure")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "STA-HOOK")
    File.mkdir_p!(workspace_root)
    SymphonyElixir.WorkspaceGitSupport.clean_checkout!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_before_remove: "exit 17"
    )

    assert {:error, {:workspace_hook_failed, "before_remove", 17, _output}, ""} =
             Workspace.remove(workspace)

    assert File.dir?(workspace)
    assert File.exists?(Path.join(workspace, "README.md"))
  end

  test "retains the workspace when Git ownership cannot be inspected" do
    root = new_root("inspection-failure")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "STA-UNKNOWN")
    File.mkdir_p!(workspace_root)
    SymphonyElixir.WorkspaceGitSupport.clean_checkout!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    git!(workspace, ["branch", "--unset-upstream"])

    assert {:error, {{:workspace_retained, "retained:unknown_upstream"}, _output}, ""} =
             Workspace.remove(workspace)

    assert File.dir?(workspace)
    git!(workspace, ["remote", "remove", "origin"])

    assert {:error, {{:workspace_retained, "retained:unknown_origin"}, _output}, ""} =
             Workspace.remove(workspace)

    missing_tracking_ref = Path.join(workspace_root, "STA-MISSING-REF")
    SymphonyElixir.WorkspaceGitSupport.clean_checkout!(missing_tracking_ref)
    git!(missing_tracking_ref, ["update-ref", "-d", "refs/remotes/origin/main"])

    assert {:error, {{:workspace_retained, "retained:unknown_upstream"}, _output}, ""} =
             Workspace.remove(missing_tracking_ref)

    assert File.dir?(missing_tracking_ref)
  end

  test "ignores unique commits on local refs outside the workspace HEAD" do
    root = new_root("unrelated-ref")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "STA-UNRELATED-REF")
    File.mkdir_p!(workspace_root)
    SymphonyElixir.WorkspaceGitSupport.clean_checkout!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    git!(workspace, ["switch", "-c", "unrelated-work"])
    File.write!(Path.join(workspace, "side-branch.txt"), "not on workspace HEAD\n")
    git!(workspace, ["add", "side-branch.txt"])
    git!(workspace, ["commit", "-m", "unrelated local branch work"])
    git!(workspace, ["switch", "main"])

    assert {:ok, []} = Workspace.remove(workspace)
    refute File.exists?(workspace)
  end

  test "does not follow a symlink workspace path during cleanup" do
    root = new_root("symlink")
    workspace_root = Path.join(root, "workspaces")
    target = Path.join(workspace_root, "real-checkout")
    link = Path.join(workspace_root, "STA-LINK")
    File.mkdir_p!(workspace_root)
    SymphonyElixir.WorkspaceGitSupport.clean_checkout!(target)
    File.ln_s!(target, link)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:error, _, _} = Workspace.remove(link)
    assert File.dir?(target)
    assert File.read!(Path.join(target, "README.md")) == "baseline\n"
  end

  test "resume reuses the same checkout path and branch without resetting unique work" do
    root = new_root("resume")
    workspace_root = Path.join(root, "workspaces")
    identifier = "STA-RESUME"
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    assert {:ok, workspace} = Workspace.create_for_issue(identifier)
    SymphonyElixir.WorkspaceGitSupport.initialize_clean_checkout!(workspace)
    File.write!(Path.join(workspace, "README.md"), "resume this\n")
    File.write!(Path.join(workspace, "partial.txt"), "partial work\n")

    assert {:ok, ^workspace} = Workspace.create_for_issue(identifier)
    assert git_output!(workspace, ["branch", "--show-current"]) == "main"
    assert File.read!(Path.join(workspace, "README.md")) == "resume this\n"
    assert File.read!(Path.join(workspace, "partial.txt")) == "partial work\n"
  end

  test "backlog cancellation and terminal reconciliation preserve dirty workspace work" do
    root = new_root("reconcile")
    identifier = "STA-RECONCILE"
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, identifier)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Closed", "Cancelled"]
    )

    File.mkdir_p!(workspace_root)
    SymphonyElixir.WorkspaceGitSupport.clean_checkout!(workspace)
    File.write!(Path.join(workspace, "README.md"), "keep across reconciliation\n")
    File.write!(Path.join(workspace, "partial.txt"), "in progress\n")
    state = state_with_running_workspace(workspace, identifier)
    backlog = %Issue{id: "issue-196", identifier: identifier, state: "Backlog", labels: []}

    updated = Orchestrator.reconcile_issue_states_for_test([backlog], state)
    refute Map.has_key?(updated.running, "issue-196")
    assert File.dir?(workspace)

    resumed_state = state_with_running_workspace(workspace, identifier)
    terminal = %Issue{id: "issue-196", identifier: identifier, state: "Cancelled", labels: []}
    _terminal_state = Orchestrator.reconcile_issue_states_for_test([terminal], resumed_state)

    assert git_output!(workspace, ["branch", "--show-current"]) == "main"
    assert File.read!(Path.join(workspace, "README.md")) == "keep across reconciliation\n"
    assert File.read!(Path.join(workspace, "partial.txt")) == "in progress\n"
  end

  test "blocked backlog and terminal cleanup keep the resumable branch and diff" do
    root = new_root("blocked")
    identifier = "STA-BLOCKED"
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, identifier)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Closed", "Cancelled"]
    )

    File.mkdir_p!(workspace_root)
    SymphonyElixir.WorkspaceGitSupport.clean_checkout!(workspace)
    File.write!(Path.join(workspace, "README.md"), "blocked changes\n")
    File.write!(Path.join(workspace, "partial.txt"), "handoff notes\n")
    issue = %Issue{id: "issue-blocked", identifier: identifier, state: "In Progress"}

    state = %Orchestrator.State{
      blocked: %{"issue-blocked" => %{issue: issue, identifier: identifier, workspace_path: workspace}},
      claimed: MapSet.new(["issue-blocked"]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    backlog = %{issue | state: "Backlog"}
    backlog_state = Orchestrator.reconcile_blocked_issue_states_for_test([backlog], state)
    refute Map.has_key?(backlog_state.blocked, "issue-blocked")
    assert File.dir?(workspace)

    assert {:ok, ^workspace} = Workspace.create_for_issue(identifier)
    terminal = %{issue | state: "Closed"}
    _terminal_state = Orchestrator.reconcile_blocked_issue_states_for_test([terminal], state)

    assert git_output!(workspace, ["branch", "--show-current"]) == "main"
    assert File.read!(Path.join(workspace, "README.md")) == "blocked changes\n"
    assert File.read!(Path.join(workspace, "partial.txt")) == "handoff notes\n"
  end

  defp state_with_running_workspace(workspace, identifier) do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        after
          5_000 -> :ok
        end
      end)

    %Orchestrator.State{
      running: %{
        "issue-196" => %{
          pid: pid,
          ref: nil,
          identifier: identifier,
          issue: %Issue{id: "issue-196", identifier: identifier, state: "In Progress"},
          workspace_path: workspace,
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new(["issue-196"]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end

  defp new_root(name) do
    root = Path.join(System.tmp_dir!(), "symphony-workspace-#{name}-#{System.unique_integer([:positive])}")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp git!(workspace, args) do
    {_output, status} = System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true)
    assert status == 0
  end

  defp git_output!(workspace, args) do
    {output, status} = System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true)
    assert status == 0
    String.trim(output)
  end
end
