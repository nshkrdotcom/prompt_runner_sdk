%{
  deps: %{
    agent_session_manager: %{
      path: "../agent_session_manager",
      github: %{repo: "nshkrdotcom/agent_session_manager", branch: "main"},
      hex: "~> 0.14.0",
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    },
    cli_subprocess_core: %{
      path: "../cli_subprocess_core",
      github: %{repo: "nshkrdotcom/cli_subprocess_core", branch: "main"},
      hex: "~> 0.6.0",
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    },
    execution_plane_process: %{
      path: "../execution_plane/runtimes/execution_plane_process",
      github: %{
        repo: "nshkrdotcom/execution_plane",
        branch: "main",
        subdir: "runtimes/execution_plane_process"
      },
      hex: "~> 0.3.0",
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    }
  }
}
