module github.com/kstepanchuk/StampSign/pdfbridge

go 1.26.0

require (
	github.com/agcom/pdfcpu-sign v0.0.0-00010101000000-000000000000
	github.com/pdfcpu/pdfcpu v0.16.3
)

replace github.com/agcom/pdfcpu-sign => ./third_party/pdfcpu-sign

require (
	github.com/clipperhouse/uax29/v2 v2.7.0 // indirect
	github.com/hhrutter/tiff v1.0.7 // indirect
	github.com/mattn/go-runewidth v0.0.31 // indirect
	github.com/smallstep/pkcs7 v0.2.1 // indirect
	github.com/xdg-go/stringprep v1.0.4 // indirect
	go.yaml.in/yaml/v3 v3.0.5 // indirect
	golang.org/x/crypto v0.58.0 // indirect
	golang.org/x/image v0.47.0 // indirect
	golang.org/x/text v0.43.0 // indirect
)
