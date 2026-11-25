module mayhem.local/agenui-gofuzz

go 1.22

require github.com/AGenUI/AGenUI/agent_sdks/go v0.0.0

require (
	github.com/dvyukov/go-fuzz v0.0.0-20240924070022-e577bee5275c // indirect
	github.com/santhosh-tekuri/jsonschema/v6 v6.0.1 // indirect
	golang.org/x/text v0.14.0 // indirect
)

replace github.com/AGenUI/AGenUI/agent_sdks/go => ../../agent_sdks/go
