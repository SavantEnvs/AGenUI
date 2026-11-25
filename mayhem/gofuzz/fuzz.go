// Package gofuzz fuzzes the AGenUI Go agent SDK's parsers of LLM output
// (agent_sdks/go/parser): ParseResponse (splits a response into text and
// A2UI JSON parts), ParseAndFix (repairs and parses a JSON payload) and the
// v0.9 streaming parser fed in chunks. FuzzValidate (validate.go) is the
// catalog-backed schema validator. Built with go-fuzz-build -libfuzzer.
package gofuzz

import (
	"io"
	"log"

	"github.com/AGenUI/AGenUI/agent_sdks/go/parser"
)

func init() {
	parser.SetLogger(log.New(io.Discard, "", 0))
}

// Fuzz: the first byte picks the streaming chunk size (1..1009, in steps of
// 16 — the streaming parser re-scans its buffer per chunk); the rest is
// the LLM response text.
func Fuzz(data []byte) int {
	if len(data) < 1 {
		return 0
	}
	chunk := int(data[0]%64)*16 + 1
	text := string(data[1:])

	parser.HasA2UIParts(text)
	parser.ParseResponse(text)
	parser.ParseAndFix(text)

	p := parser.NewA2uiStreamParser(nil)
	for off := 0; off < len(text); off += chunk {
		end := off + chunk
		if end > len(text) {
			end = len(text)
		}
		p.ProcessChunk(text[off:end])
	}
	return 0
}
