#[derive(Debug, Clone, Default)]
/// Splits cleaned TTS text into synthesis-sized segments.
pub struct TtsSegmenter;

impl TtsSegmenter {
    /// Segments text without exceeding the requested maximum character count.
    ///
    /// 旧实现每 maxChars 个字符硬切，可能从一句话、一个英文单词或一个数值中间
    /// 劈开，听感就是突兀断句。现在优先在句号、问号、分号或换行处切；
    /// 只有长句确实没有边界时才硬切，并优先退到最近空白。
    pub fn segment(text: &str, maxChars: usize) -> Vec<String> {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return Vec::new();
        }
        if maxChars == 0 {
            return vec![trimmed.to_string()];
        }

        let chars: Vec<(usize, char)> = trimmed.char_indices().collect();
        if chars.len() <= maxChars {
            return vec![trimmed.to_string()];
        }

        let mut result = Vec::new();
        let mut start = 0usize;
        while start < chars.len() {
            let remaining = chars.len() - start;
            if remaining <= maxChars {
                pushNonEmpty(&mut result, &trimmed[chars[start].0..]);
                break;
            }

            let hardEnd = start + maxChars;
            let earliest = start + (maxChars / 2).max(1);
            let mut sentenceEnd = None;
            let mut whitespaceEnd = None;
            for index in earliest..hardEnd {
                let character = chars[index].1;
                if matches!(character, '。' | '！' | '？' | '!' | '?' | '；' | ';' | '\n') {
                    sentenceEnd = Some(index + 1);
                } else if character.is_whitespace() {
                    whitespaceEnd = Some(index + 1);
                } else if character == '.'
                    && chars
                        .get(index + 1)
                        .is_some_and(|(_, next)| next.is_whitespace())
                {
                    sentenceEnd = Some(index + 1);
                }
            }

            let end = sentenceEnd.or(whitespaceEnd).unwrap_or(hardEnd);
            let byteStart = chars[start].0;
            let byteEnd = if end < chars.len() {
                chars[end].0
            } else {
                trimmed.len()
            };
            pushNonEmpty(&mut result, &trimmed[byteStart..byteEnd]);
            start = end;
        }
        result
    }
}

fn pushNonEmpty(result: &mut Vec<String>, text: &str) {
    let trimmed = text.trim();
    if !trimmed.is_empty() {
        result.push(trimmed.to_string());
    }
}

#[cfg(test)]
mod tests {
    use super::TtsSegmenter;

    #[test]
    fn cuts_at_sentence_boundary_instead_of_mid_sentence() {
        let segments = TtsSegmenter::segment("第一句完整的话。第二句也不应该被劈开！第三句", 12);
        assert_eq!(segments, vec!["第一句完整的话。", "第二句也不应该被劈开！", "第三句"]);
    }

    #[test]
    fn every_segment_respects_limit() {
        let segments = TtsSegmenter::segment("没有标点的一串字符abcdefghijklmn", 8);
        assert!(segments.iter().all(|segment| segment.chars().count() <= 8));
        assert_eq!(segments.concat(), "没有标点的一串字符abcdefghijklmn");
    }

    #[test]
    fn does_not_split_utf8_codepoints() {
        let segments = TtsSegmenter::segment("中文中文中文中文", 3);
        assert_eq!(segments.concat(), "中文中文中文中文");
    }
}
