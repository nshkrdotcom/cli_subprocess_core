%{
  deps: %{
    execution_plane: %{
      path: "../execution_plane/core/execution_plane",
      github: %{
        repo: "nshkrdotcom/execution_plane",
        branch: "main",
        subdir: "core/execution_plane"
      },
      hex: "~> 0.2.0",
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
      hex: "~> 0.1.0",
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    },
    execution_plane_jsonrpc: %{
      path: "../execution_plane/protocols/execution_plane_jsonrpc",
      github: %{
        repo: "nshkrdotcom/execution_plane",
        branch: "main",
        subdir: "protocols/execution_plane_jsonrpc"
      },
      hex: "~> 0.1.0",
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    },
    ground_plane_contracts: %{
      path: "../ground_plane/core/ground_plane_contracts",
      github: %{
        repo: "nshkrdotcom/ground_plane",
        branch: "main",
        subdir: "core/ground_plane_contracts"
      },
      hex: "~> 0.1.0",
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    },
    ground_plane_persistence_policy: %{
      path: "../ground_plane/core/persistence_policy",
      github: %{
        repo: "nshkrdotcom/ground_plane",
        branch: "main",
        subdir: "core/persistence_policy"
      },
      hex: "~> 0.1.0",
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    }
  }
}
