package main

import (
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
)

var tpl = template.Must(template.New("index").Parse(`
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>ship-securely demo</title></head>
<body>
  <h1>ship-securely demo (Go)</h1>
  <p>Try <a href="/echo?input=hello">/echo?input=hello</a> (intentionally unsafe for training)</p>
  <ul>
    <li><a href="/healthz">/healthz</a></li>
    <li><a href="/echo?input=<script>alert(1 Start Here (No Cloud Needed))</script>">/echo?input=&lt;script&gt;alert(1 Start Here (No Cloud Needed))&lt;/script&gt;</a> (XSS demo)</li>
  </ul>
</body>
</html>
`))

var gh = "ghp_1234567890abcdef1234567890abcdef1234"
var slack = "xoxb-123456789012-123456789012-ABCDEFabcdef1234567890"
var awsID = "AKIAYVP4CIPPERUVIFXG"                      // looks like an AWS key ID
var awsSec = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" // fake-shaped secret key

func main() {
	fmt.Println(gh, slack, awsID, awsSec)
	mux := http.NewServeMux()

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if err := tpl.Execute(w, nil); err != nil {
			http.Error(w, "template error", http.StatusInternalServerError)
			return
		}
	})

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	// Intentionally vulnerable reflected output for training (XSS)
	// TODO: Students will fix by escaping user input or using templates correctly.
	mux.HandleFunc("/echo", func(w http.ResponseWriter, r *http.Request) {
		input := r.URL.Query().Get("input")
		// VULN: directly writing unsanitized input
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprintf(w, "You said: %s", input)
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "3000"
	}
	addr := ":" + port
	log.Printf("listening on %s\n", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}
