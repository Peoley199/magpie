package gateway

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// zcodeStartVendor is a Start Plan as zcode.z.ai answered one on 10-23: a
// request whose system has any text is turned away with 405 and code 3012,
// one with none is answered.
type zcodeStartVendor struct {
	mu      sync.Mutex
	systems []any
	bodies  []map[string]any
}

func (z *zcodeStartVendor) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var b map[string]any
	_ = json.NewDecoder(r.Body).Decode(&b)
	z.mu.Lock()
	z.systems = append(z.systems, b["system"])
	z.bodies = append(z.bodies, b)
	z.mu.Unlock()
	if systemText(b["system"]) != "" {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(405)
		w.Write([]byte(`{"code":3012,"msg":"Method Not Allowed","data":null}`))
		return
	}
	// as the vendor streams one
	w.Header().Set("Content-Type", "text/event-stream")
	for _, e := range []string{
		`event: message_start` + "\n" + `data: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","model":"fake-claude","content":[],"usage":{"input_tokens":1,"output_tokens":0}}}`,
		`event: content_block_start` + "\n" + `data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"ok"}}`,
		`event: content_block_stop` + "\n" + `data: {"type":"content_block_stop","index":0}`,
		`event: message_delta` + "\n" + `data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}`,
		`event: message_stop` + "\n" + `data: {"type":"message_stop"}`,
	} {
		io.WriteString(w, e+"\n\n")
	}
}

// A Start Plan account (a moved ZCode whose sign-in keeps no Coding Plan
// key) is sent the agent's system text in front of its first turn instead
// of a system prompt, which the plan turns away; a Coding Plan key's
// account keeps it.
func TestZCodeStartPlanTakesNoSystem(t *testing.T) {
	v := &zcodeStartVendor{}
	movedFake(t, "zcode", v)
	s := New()
	body := `{"model":"zcode/fake-claude","system":"You are a coding agent.","messages":[{"role":"user","content":[{"type":"text","text":"find the bug"}]}]}`
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest("POST", "/v1/messages", strings.NewReader(body)))
	if rec.Code != 200 {
		t.Fatalf("Start Plan: %d %s", rec.Code, rec.Body)
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if len(v.systems) != 1 {
		t.Fatalf("asked %d times", len(v.systems))
	}
	if systemText(v.systems[0]) != "" {
		t.Fatalf("the system went to the Start Plan: %v", v.systems[0])
	}
	msgs := v.bodies[0]["messages"].([]any)
	first, _ := json.Marshal(msgs[0])
	if !strings.Contains(string(first), "You are a coding agent.") || !strings.Contains(string(first), "find the bug") {
		t.Fatalf("the system's text isn't in front of the first turn: %s", first)
	}
}

// withoutZCodeSystem: a string system joins the first user turn's text; the
// blocks of an array one go in order before that turn's blocks; a system
// message inside messages stays; no system is left as it was.
func TestWithoutZCodeSystem(t *testing.T) {
	got := withoutZCodeSystem([]byte(`{"model":"m","system":"A","messages":[{"role":"user","content":"hi"}]}`))
	var v map[string]any
	if json.Unmarshal(got, &v) != nil {
		t.Fatal(got)
	}
	if _, ok := v["system"]; ok {
		t.Fatalf("system kept: %s", got)
	}
	if c := v["messages"].([]any)[0].(map[string]any)["content"]; c != "A\n\nhi" {
		t.Fatalf("first turn: %q", c)
	}
	got = withoutZCodeSystem([]byte(`{"system":[{"type":"text","text":"A"},{"type":"text","text":"B","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}`))
	if json.Unmarshal(got, &v) != nil {
		t.Fatal(got)
	}
	blocks := v["messages"].([]any)[0].(map[string]any)["content"].([]any)
	if len(blocks) != 2 || blocks[0].(map[string]any)["text"] != "A\n\nB" || blocks[1].(map[string]any)["text"] != "hi" {
		t.Fatalf("blocks: %v", blocks)
	}
	in := `{"system":"A","messages":[{"role":"user","content":"x"},{"role":"system","content":"s"},{"role":"user","content":"y"}]}`
	if got := withoutZCodeSystem([]byte(in)); !strings.Contains(string(got), `"role":"system"`) {
		t.Fatalf("the system message went: %s", got)
	}
	in = `{"model":"m","messages":[{"role":"user","content":"hi"}]}`
	if got := withoutZCodeSystem([]byte(in)); string(got) != in {
		t.Fatalf("no system changed: %s", got)
	}
}
