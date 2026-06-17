module github.com/explorejournal/frpmobile

go 1.22

// Pin frp to the version you build + test against. The embedding API
// (client.NewService / pkg/config.LoadClientConfig / UpdateAllConfigurer)
// is stable across v0.52–v0.6x but DO verify against your pinned tag.
require github.com/fatedier/frp v0.58.1

// `gomobile bind` pulls the rest transitively; run `go mod tidy` in CI.
