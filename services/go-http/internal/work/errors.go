package work

import (
	"encoding/json"
	"net/http"
)

type errorBody struct {
	OK    bool       `json:"ok"`
	Error errorInner `json:"error"`
}

type errorInner struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func writeError(w http.ResponseWriter, status int, code string, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)

	_ = json.NewEncoder(w).Encode(errorBody{
		OK: false,
		Error: errorInner{
			Code:    code,
			Message: message,
		},
	})
}
