package gofuzz

import (
	"encoding/json"
	"io"
	"log"

	"github.com/AGenUI/AGenUI/agent_sdks/go/basiccatalog"
	"github.com/AGenUI/AGenUI/agent_sdks/go/parser"
	"github.com/AGenUI/AGenUI/agent_sdks/go/schema"
)

// The bundled v0.9 basic catalog and its validator, built once. Both are
// read-only per input: Validate only reads the catalog, and the validator's
// jsonschema compiler memoises schemas it compiles by ref, where every ref is
// either a fixed S2C $defs name or "catalog.json#/components/<type>" for a
// <type> that must already exist in the catalog, so the cache only ever holds
// the same fixed schemas whatever the input order.
var (
	validatorCatalog *schema.A2uiCatalog
	a2uiValidator    *schema.A2uiValidator
)

func init() {
	schema.SetLogger(log.New(io.Discard, "", 0))
	cfg := basiccatalog.GetConfig(schema.Version09, "")
	m, err := schema.NewA2uiSchemaManager(schema.A2uiSchemaManagerConfig{
		Version:  schema.Version09,
		Catalogs: []*schema.CatalogConfig{&cfg},
	})
	if err != nil {
		panic(err)
	}
	validatorCatalog, err = m.GetSelectedCatalog(nil, nil, nil)
	if err != nil {
		panic(err)
	}
	a2uiValidator = schema.NewA2uiValidator(validatorCatalog)
}

// FuzzValidate: the Go SDK's validation of LLM-generated A2UI against the
// basic catalog (agent_sdks/go/schema: JSON Schema per message, component
// integrity, topology, recursion and path checks). Same input format as Fuzz:
// the first byte's low 6 bits pick the streaming chunk size and bit 6 picks
// strict integrity; the rest is the LLM response text. It goes through the
// catalog-backed streaming parser (which validates each completed message),
// through ParseResponse with each part's messages validated, and, when the
// text is plain JSON, straight into Validate.
func FuzzValidate(data []byte) int {
	if len(data) < 1 {
		return 0
	}
	chunk := int(data[0]%64)*16 + 1
	strict := data[0]&0x40 != 0
	text := string(data[1:])

	p := parser.NewA2uiStreamParser(validatorCatalog)
	for off := 0; off < len(text); off += chunk {
		end := off + chunk
		if end > len(text) {
			end = len(text)
		}
		p.ProcessChunk(text[off:end])
	}

	if parts, err := parser.ParseResponse(text); err == nil {
		for _, part := range parts {
			if part.A2UIJSON == nil {
				continue
			}
			msgs := make([]any, len(part.A2UIJSON))
			for i, m := range part.A2UIJSON {
				msgs[i] = m
			}
			a2uiValidator.Validate(msgs, "", strict)
		}
	}

	var v any
	if json.Unmarshal(data[1:], &v) == nil {
		a2uiValidator.Validate(v, "", strict)
	}
	return 0
}
