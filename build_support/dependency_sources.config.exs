%{
  deps: %{
    execution_plane: %{
      path: "../execution_plane/dist/monolith/execution_plane",
      github: %{
        repo: "nshkrdotcom/execution_plane",
        branch: "projection/execution_plane"
      },
      hex: "~> 0.1.0",
      default_order: [:path, :github, :hex],
      publish_order: [:hex]
    }
  }
}
