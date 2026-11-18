# Cross-platform desktop application

The `StampSign.Desktop.slnx` solution is the shared .NET/Avalonia StampSign application for macOS and Windows.

## Architecture

- `StampSign.Desktop`: Avalonia UI shared by macOS and Windows.
- `StampSign.Core`: CMS/CAdES parsing and signature verification, backed by Bouncy Castle.
- `StampSign.Pdf`: PDF rendering with PDFium and a thin wrapper for the bundled pdfcpu bridge.
- `PdfBridge`: small Go helper using pdfcpu for vector-preserving page stamps and file attachments.
- `Signing/cades-sign.html`: local CryptoPro Browser plug-in page for creating detached or attached CMS `.sig` files. It receives the PDF over loopback and never sends the document to a remote service.
- PAdES signing reserves the PDF `/ByteRange` with pdfcpu-sign and requests the detached CMS from CryptoPro in the local browser page.
- PAdES extraction returns the CMS container and concatenated signed byte ranges to the shared CMS verifier when a signed PDF is opened.

PDF editing intentionally uses pdfcpu (Apache-2.0); PDFsharp was excluded because its current licensing would conflict with StampSign's MIT distribution. The crypto-arm implementation is not copied.

## Build

The `Cross-platform desktop` GitHub Actions workflow builds a self-contained Windows x64 folder and DMG images for macOS Apple Silicon and Intel. The macOS DMGs contain an ad-hoc signed `StampSign.app` and an `Applications` shortcut for drag-and-drop installation. The build is not notarized. Local builds need .NET 10 and Go 1.26. Build the PDF helper first so it is placed in `StampSign.Desktop/tools`:

Creating CMS signatures requires CryptoPro CSP and its browser plug-in/extension. The signing page loads the official CryptoPro JavaScript bridge from `cryptopro.ru`; the PDF itself stays on the local machine.

```sh
cd Desktop/PdfBridge
mkdir -p ../StampSign.Desktop/tools
go build -o ../StampSign.Desktop/tools/stamp-pdf .
cd ../..
dotnet publish Desktop/StampSign.Desktop/StampSign.Desktop.csproj -c Release -r osx-arm64 --self-contained true
```

For a Windows build, compile the helper with `GOOS=windows GOARCH=amd64` to `Desktop/StampSign.Desktop/tools/stamp-pdf.exe`, then publish with `-r win-x64`. Use `osx-x64` for Intel Mac. Tagged releases publish the Windows ZIP and both macOS DMGs.
