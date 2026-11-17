# Сторонние материалы

## gostcrypto

Файлы `Sources/StampSign/StreebogTables.swift` и `Sources/StampSign/GOSTCurves.swift` сгенерированы из таблиц и параметров кривых проекта [gostcrypto](https://github.com/drobotun/gostcrypto) версии 1.2.5 (таблицы преобразования и константы Стрибога, параметры эллиптических кривых ГОСТ Р 34.10-2012). Алгоритмы написаны заново на Swift. Исходный код gostcrypto в репозиторий не включён.

```
MIT License

Copyright (c) 2020 Дроботун Евгений

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Стандарты

Реализация следует ГОСТ Р 34.11-2012 (RFC 6986), ГОСТ Р 34.10-2012 (RFC 7091) и RFC 5652 (CMS). Тестовые векторы взяты из RFC 6986 и RFC 7091.
# Cross-platform desktop application

The in-progress Avalonia desktop app uses these third-party projects:

- Avalonia UI — MIT License.
- Bouncy Castle C# cryptography — MIT License.
- PDFtoImage and SkiaSharp — MIT Licenses; PDFium components carry their upstream BSD-style license.
- pdfcpu — Apache License 2.0. The PDF bridge is a small independent wrapper around its API; the license text is in `Desktop/PdfBridge/LICENSE.txt`.
- pdfcpu-sign — Apache License 2.0. StampSign's external-CMS callback fork and its license are in `Desktop/PdfBridge/third_party/pdfcpu-sign`.
- pdfcpu-sign — Apache License 2.0. StampSign's small fork adds a detached-CMS callback for CryptoPro; source and license are in `Desktop/PdfBridge/third_party/pdfcpu-sign`.

See each upstream project's license for complete terms and required notices.
