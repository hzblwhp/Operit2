use regex::Regex;

#[derive(Debug, Clone, Default)]
/// Cleans chat text before TTS synthesis.
pub struct TtsCleaner;

impl TtsCleaner {
    /// Removes markup and whitespace that should not be spoken.
    ///
    /// 聊天正文不是纯文本：代码块、Markdown 链接、工具 XML、思考块、图片地址
    /// 都会混进来。旧实现只 trim()，于是系统会把这些符号逐字念出来。
    /// 这里只保留人耳真正需要的内容，并保留句读，供分段器决定自然停顿。
    pub fn clean(text: &str) -> String {
        let mut value = text.replace("\r\n", "\n").replace('\r', "\n");

        // 思考块不是最终回复，不能回读。未闭合的 thinking 尾部也一并丢弃。
        value = replace(
            &value,
            r"(?is)<think(?:ing)?\b[^>]*>.*?</think(?:ing)?\s*>",
            " ",
        );
        value = replace(&value, r"(?is)<think(?:ing)?\b[^>]*>.*$", " ");

        // 工具调用、附件、记忆注入等结构化内容不属于可朗读正文。
        for tag in [
            "tool_call",
            "tool_result",
            "status",
            "attachment",
            "workspace_attachment",
            "reply_to",
            "memory_context",
            "proxy_sender",
        ] {
            value = replace(
                &value,
                &format!(r"(?is)<{tag}\b[^>]*>.*?</{tag}\s*>"),
                " ",
            );
            value = replace(&value, &format!(r"(?is)<{tag}\b[^>]*/>"), " ");
        }

        // 代码语法不适合逐字朗读；用一句短说明保留上下文连续性。
        value = replace(&value, r"(?is)```[^\n]*\n?.*?```", " 代码内容省略。 ");
        value = replace(&value, r"(?is)```[^\n]*\n?.*$", " 代码内容省略。 ");
        value = replace(&value, r"`([^`]*)`", "$1");

        // 图片与链接只读可读标题，不读 URL。
        value = replace(&value, r"!\[([^\]]*)\]\([^)]*\)", "$1");
        value = replace(&value, r"\[([^\]]+)\]\([^)]*\)", "$1");
        value = replace(&value, r"https?://[^\s<>()]+", "链接");

        // Markdown 结构与表格线去掉，文本本身保留。
        value = replace(&value, r"(?m)^\s{0,3}#{1,6}\s+", "");
        value = replace(&value, r"(?m)^\s*>\s?", "");
        value = replace(&value, r"(?m)^\s*[-*+]\s+", "");
        value = replace(&value, r"(?m)^\s*\d+[.)]\s+", "");
        value = replace(&value, r"(?m)^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$", "");
        value = value.replace(['*', '_', '~'], "");
        value = value.replace('|', "，");
        value = replace(&value, r"</?[A-Za-z][^>]*>", " ");

        // 连续空白会让引擎出现不稳定的拖音；换行保留为自然停顿。
        value = replace(&value, r"[ \t\u{00a0}]+", " ");
        value = replace(&value, r" *\n+ *", "\n");
        value = replace(&value, r"\n{3,}", "\n\n");
        value.trim().to_string()
    }
}

fn replace(text: &str, pattern: &str, replacement: &str) -> String {
    Regex::new(pattern)
        .map(|regex| regex.replace_all(text, replacement).into_owned())
        .unwrap_or_else(|_| text.to_string())
}

#[cfg(test)]
mod tests {
    use super::TtsCleaner;

    #[test]
    fn removes_markup_without_deleting_readable_text() {
        let input = r#"<think>内部推理</think>## 结论
**可以了**。[详细说明](https://example.com/a?x=1)
```rust
fn main() { println!("不读"); }
```
- 第一项
> 第二项"#;
        let output = TtsCleaner::clean(input);
        assert!(!output.contains("内部推理"));
        assert!(!output.contains("fn main"));
        assert!(!output.contains("example.com"));
        assert!(output.contains("可以了"));
        assert!(output.contains("详细说明"));
        assert!(output.contains("第一项"));
        assert!(output.contains("第二项"));
    }

    #[test]
    fn preserves_sentence_punctuation() {
        let output = TtsCleaner::clean("第一句。第二句！\n第三句？");
        assert_eq!(output, "第一句。第二句！\n第三句？");
    }
}
