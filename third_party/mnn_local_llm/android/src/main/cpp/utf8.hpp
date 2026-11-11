#pragma once

#include <cstdint>
#include <string>

namespace mnn_bridge {

// MNN's per-token generate_str delta can end in the middle of a multi-byte
// UTF-8 sequence. Return the length of the longest prefix that contains only
// complete sequences; the caller buffers the remainder for the next token.
inline size_t completeUtf8Length(const std::string& text) {
    size_t i = 0;
    size_t lastComplete = 0;
    while (i < text.size()) {
        const unsigned char c = static_cast<unsigned char>(text[i]);
        size_t length = 0;
        if (c < 0x80) {
            length = 1;
        } else if ((c & 0xE0) == 0xC0) {
            length = 2;
        } else if ((c & 0xF0) == 0xE0) {
            length = 3;
        } else if ((c & 0xF8) == 0xF0) {
            length = 4;
        } else {
            // Invalid leading byte: consume it so the caller can replace it.
            ++i;
            lastComplete = i;
            continue;
        }

        if (i + length > text.size()) break;  // incomplete tail
        bool valid = true;
        for (size_t j = 1; j < length; ++j) {
            if ((static_cast<unsigned char>(text[i + j]) & 0xC0) != 0x80) {
                valid = false;
                break;
            }
        }
        if (!valid) {
            ++i;
            lastComplete = i;
            continue;
        }
        i += length;
        lastComplete = i;
    }
    return lastComplete;
}

// Decode standard UTF-8 (including 4-byte supplementary characters) to UTF-16.
// Invalid/incomplete bytes become U+FFFD, so the result is always safe for
// JNIEnv::NewString (which, unlike NewStringUTF, accepts surrogate pairs).
inline std::u16string utf8ToUtf16(const std::string& text) {
    std::u16string out;
    size_t i = 0;
    while (i < text.size()) {
        const unsigned char c = static_cast<unsigned char>(text[i]);
        uint32_t codePoint = 0;
        size_t length = 0;
        if (c < 0x80) {
            codePoint = c;
            length = 1;
        } else if ((c & 0xE0) == 0xC0) {
            codePoint = c & 0x1F;
            length = 2;
        } else if ((c & 0xF0) == 0xE0) {
            codePoint = c & 0x0F;
            length = 3;
        } else if ((c & 0xF8) == 0xF0) {
            codePoint = c & 0x07;
            length = 4;
        } else {
            out.push_back(0xFFFD);
            ++i;
            continue;
        }

        if (i + length > text.size()) {
            out.push_back(0xFFFD);
            break;
        }

        bool valid = true;
        for (size_t j = 1; j < length; ++j) {
            const unsigned char next = static_cast<unsigned char>(text[i + j]);
            if ((next & 0xC0) != 0x80) {
                valid = false;
                break;
            }
            codePoint = (codePoint << 6) | (next & 0x3F);
        }
        if (!valid || codePoint > 0x10FFFF) {
            out.push_back(0xFFFD);
            ++i;
            continue;
        }

        if (codePoint <= 0xFFFF) {
            out.push_back(static_cast<char16_t>(codePoint));
        } else {
            codePoint -= 0x10000;
            out.push_back(static_cast<char16_t>(0xD800 + (codePoint >> 10)));
            out.push_back(static_cast<char16_t>(0xDC00 + (codePoint & 0x3FF)));
        }
        i += length;
    }
    return out;
}

}  // namespace mnn_bridge
