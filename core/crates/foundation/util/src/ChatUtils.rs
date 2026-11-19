use crate::ChatMarkupRegex::ChatMarkupRegex;
use regex::Regex;

/// Utility functions for chat content cleanup, extraction, and rough token estimates.
pub struct ChatUtils;

impl ChatUtils {
    /// Removes Gemini thought-signature metadata from one message body.
    pub fn strip_gemini_thought_signature_meta(content: &str) -> String {
        ChatMarkupRegex::remove_gemini_thought_signature_meta(content)
    }

    /// Removes Gemini thought-signature metadata from role/content message pairs.
    pub fn strip_gemini_thought_signature_meta_messages(
        messages: &[(String, String)],
    ) -> Vec<(String, String)> {
        messages
            .iter()
            .map(|(role, content)| {
                (
                    role.clone(),
                    Self::strip_gemini_thought_signature_meta(content),
                )
            })
            .collect()
    }

    /// Returns whether a provider-model id belongs to a Gemini provider.
    pub fn is_gemini_provider_model(provider_model: &str) -> bool {
        matches!(
            provider_model
                .split(':')
                .next()
                .unwrap_or("")
                .to_ascii_uppercase()
                .as_str(),
            "GOOGLE" | "GEMINI_GENERIC"
        )
    }

    /// Escapes raw thinking delimiters inside model-provided reasoning text.
    ///
    /// Reasoning chunks are re-wrapped as `<think>...</think>` before they reach the
    /// streaming parser. If the model itself prints a thinking delimiter (quoting one,
    /// discussing the protocol, or emitting the marker as code), the wrapper closes
    /// early and every following reasoning token is rendered as visible answer text.
    /// A zero-width space after `<` keeps the text readable while making the sequence
    /// non-matching for the protocol regexes.
    pub fn escape_thinking_markup(content: &str) -> String {
        content
            .replace("</think", "<\u{200B}/think")
            .replace("<think", "<\u{200B}think")
    }

    /// Removes thinking and search markup from visible assistant content.
    /// Escapes thinking markup in one streamed reasoning delta.
    ///
    /// Replacing per delta is not enough: a delimiter split across two deltas
    /// matches nothing on either side on its own, yet concatenating them produces
    /// the real delimiter and closes the block early. A tail that could still grow
    /// into a delimiter is therefore held back in `pending` and prepended to the
    /// next delta instead of being emitted.
    pub fn escape_thinking_markup_streaming(pending: &mut String, delta: &str) -> String {
        pending.push_str(delta);
        let mut holdback = 0usize;
        for delimiter in ["</think", "<think"] {
            for length in 1..delimiter.len() {
                if pending.ends_with(&delimiter[..length]) {
                    holdback = holdback.max(length);
                }
            }
        }
        if holdback == 0 {
            let escaped = Self::escape_thinking_markup(pending);
            pending.clear();
            return escaped;
        }
        let split_at = pending.len() - holdback;
        let head = pending[..split_at].to_string();
        let tail = pending[split_at..].to_string();
        *pending = tail;
        Self::escape_thinking_markup(&head)
    }

    /// Flushes the tail held back by `escape_thinking_markup_streaming`.
    pub fn flush_thinking_markup_streaming(pending: &mut String) -> String {
        if pending.is_empty() {
            return String::new();
        }
        let escaped = Self::escape_thinking_markup(pending);
        pending.clear();
        escaped
    }

    pub fn remove_thinking_content(content: &str) -> String {
        let think_pattern =
            Regex::new(r"(?s)<think(?:ing)?>.*?(</think(?:ing)?>|\z)").expect("think regex");
        let search_pattern = Regex::new(r"(?s)<search>.*?(</search>|\z)").expect("search regex");
        let think_removed = think_pattern.replace_all(content, "");
        let without_blocks = search_pattern.replace_all(&think_removed, "");
        // A closing delimiter with no opening delimiter reaches this point when the model
        // prints one by itself (reasoning-budget cut-off, or the text merely quoting it).
        // Drop the bare delimiter so it never shows up in the answer, but keep the
        // surrounding text: deleting it would also delete legitimate answer content.
        let orphan_pattern = Regex::new(r"(?s)</think(?:ing)?>").expect("orphan think regex");
        orphan_pattern
            .replace_all(&without_blocks, "")
            .trim()
            .to_string()
    }

    /// Splits visible content from extracted thinking text.
    pub fn extract_thinking_content(content: &str) -> (String, String) {
        let think_pattern =
            Regex::new(r"(?s)<think(?:ing)?>(.*?)</think(?:ing)?>").expect("think regex");
        let thinking = think_pattern
            .captures_iter(content)
            .map(|capture| {
                capture
                    .get(1)
                    .map(|value| value.as_str())
                    .unwrap_or("")
                    .trim()
            })
            .collect::<Vec<_>>()
            .join("\n");
        let search_pattern = Regex::new(r"(?s)<search>.*?(</search>|\z)").expect("search regex");
        let content_without_think = search_pattern
            .replace_all(&think_pattern.replace_all(content, ""), "")
            .trim()
            .to_string();
        (content_without_think, thinking)
    }

    /// Estimates token count using a lightweight character-based heuristic.
    pub fn estimate_token_count(text: &str) -> i64 {
        let chinese_char_count = text
            .chars()
            .filter(|ch| ('\u{4E00}'..='\u{9FFF}').contains(ch))
            .count();
        let other_char_count = text.chars().count().saturating_sub(chinese_char_count);
        ((chinese_char_count as f64 * 1.5) + (other_char_count as f64 * 0.25)).ceil() as i64
    }

    /// Extracts a JSON object string from an assistant response.
    pub fn extract_json(response: &str) -> String {
        let text = strip_markdown_fence(response.trim());
        let first = text.find('{');
        let last = text.rfind('}');
        match (first, last) {
            (Some(start), Some(end)) if start < end => text[start..=end].to_string(),
            _ => text.to_string(),
        }
    }

    /// Extracts a JSON array string from an assistant response.
    pub fn extract_json_array(response: &str) -> String {
        let text = strip_markdown_fence(response.trim());
        let first = text.find('[');
        let last = text.rfind(']');
        match (first, last) {
            (Some(start), Some(end)) if start < end => text[start..=end].to_string(),
            _ => text.to_string(),
        }
    }
}

fn strip_markdown_fence(text: &str) -> &str {
    if !text.starts_with("```") {
        return text;
    }
    let mut lines = text.lines();
    lines.next();
    let mut collected: Vec<&str> = lines.collect();
    if collected
        .last()
        .map(|line| line.trim() == "```")
        .unwrap_or(false)
    {
        collected.pop();
    }
    let start = text.find('\n').map(|index| index + 1).unwrap_or(text.len());
    let end = if text.trim_end().ends_with("```") {
        text.rfind("```").unwrap_or(text.len())
    } else {
        text.len()
    };
    text[start..end].trim()
}

#[cfg(test)]
mod tests {
    use super::ChatUtils;

    #[test]
    fn remove_thinking_content_mirrors_kt_pure_thinking_detection() {
        assert_eq!(ChatUtils::remove_thinking_content("<think>abc</think>"), "");
        assert_eq!(
            ChatUtils::remove_thinking_content("<thinking>abc</thinking>"),
            ""
        );
        assert_eq!(ChatUtils::remove_thinking_content("<think>abc"), "");
        assert_eq!(
            ChatUtils::remove_thinking_content("<think>abc</think>\n正文"),
            "正文"
        );
        assert_eq!(
            ChatUtils::remove_thinking_content("<search>source</search>\n正文"),
            "正文"
        );
    }

    #[test]
    fn extract_thinking_content_mirrors_kt_closed_think_extraction() {
        assert_eq!(
            ChatUtils::extract_thinking_content("<think>a</think>\n正文<search>x"),
            ("正文".to_string(), "a".to_string())
        );
        assert_eq!(
            ChatUtils::extract_thinking_content("<think>a</think><thinking>b</thinking>正文"),
            ("正文".to_string(), "a\nb".to_string())
        );
    }
}
