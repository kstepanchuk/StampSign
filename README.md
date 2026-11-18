# StampSign

[![Desktop builds](https://github.com/kstepanchuk/StampSign/actions/workflows/desktop.yml/badge.svg)](https://github.com/kstepanchuk/StampSign/actions/workflows/desktop.yml)
![Windows + macOS](https://img.shields.io/badge/platform-Windows%20%7C%20macOS-blue)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Кроссплатформенное приложение для PDF и российских электронных подписей. Один Avalonia/.NET интерфейс собирается для Windows и macOS.

## Возможности

- Открытие PDF и просмотр страниц.
- Проверка откреплённых и прикреплённых CMS/CAdES подписей `.sig`.
- Определение встроенной PAdES подписи при открытии PDF и локальная проверка её CMS, messageDigest и встроенной цепочки.
- Создание откреплённой или прикреплённой CMS подписи через установленный CryptoPro Browser plug-in.
- Добавление видимого штампа и создание встроенной PAdES подписи через CryptoPro.
- Размещение штампа по координатам, на выбранной странице или на всех страницах.
- Предварительный просмотр штампа поверх PDF: перемещение мышью, изменение ширины за угол, быстрые позиции и точное смещение стрелками.
- Передача документов signing-странице только по loopback `localhost`; файл не загружается на удалённый сервер.

Для создания подписи нужен CryptoPro CSP и расширение CryptoPro Browser plug-in в поддерживаемом браузере. StampSign не получает и не экспортирует закрытый ключ. Signing page загружает официальный JavaScript bridge с `cryptopro.ru`.

Проверка подписи локально подтверждает CMS подпись и целостность содержимого. Срок сертификата сопоставляется с временем из CMS, если оно есть; поле `signingTime` задаётся подписантом, а RFC 3161 метка времени пока не проверяется криптографически. Доверие к корневому УЦ и отзыв сертификата в текущей версии не оцениваются.

## Установка

Сборки для Windows x64 и macOS (Apple Silicon / Intel) публикуются как GitHub Actions artifacts и в GitHub Releases:

- Windows: ZIP с self-contained приложением.
- macOS: DMG с приложением и ссылкой `Applications`.

macOS сборка подписывается ad-hoc и не нотарифицируется.

## Сборка

Требуются .NET 10 и Go 1.26. PDF helper нужно собрать до публикации приложения:

```sh
cd Desktop/PdfBridge
mkdir -p ../StampSign.Desktop/tools
go build -o ../StampSign.Desktop/tools/stamp-pdf .
cd ../..
dotnet publish Desktop/StampSign.Desktop/StampSign.Desktop.csproj -c Release -r osx-arm64 --self-contained true
```

Для Windows helper соберите с `GOOS=windows GOARCH=amd64` в `Desktop/StampSign.Desktop/tools/stamp-pdf.exe`, затем используйте `-r win-x64`. Для Intel Mac используйте `-r osx-x64`.

## Архитектура и лицензии

- `Desktop/StampSign.Desktop` — общий Avalonia UI.
- `Desktop/StampSign.Core` — CMS/CAdES и проверка подписей через Bouncy Castle.
- `Desktop/StampSign.Pdf` и `Desktop/PdfBridge` — PDFium для просмотра и pdfcpu для штампа, вложений и PAdES ByteRange.
- `Desktop/StampSign.Desktop/Signing` — локальная интеграция с CryptoPro Browser plug-in.

Сторонние лицензии и изменения описаны в [NOTICE.md](NOTICE.md). Реализация `crypto-arm` не копировалась.
