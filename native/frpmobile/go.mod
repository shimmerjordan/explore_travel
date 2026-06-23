module github.com/explorejournal/frpmobile

go 1.22

// Pin frp to the version you build + test against. The embedding API
// (client.NewService / pkg/config.LoadClientConfig / UpdateAllConfigurer)
// is stable across v0.52–v0.6x but DO verify against your pinned tag.
require github.com/fatedier/frp v0.58.1

// frp's deps are pulled transitively by `go mod tidy` in CI. `gomobile bind`
// ALSO needs golang.org/x/mobile in the module graph, but frp.go doesn't import
// it so tidy won't keep it — CI adds it with `go get golang.org/x/mobile@latest`
// (after tidy) before binding.
