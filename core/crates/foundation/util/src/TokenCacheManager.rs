use crate::AppLogger::AppLogger;
use crate::ChatUtils::ChatUtils;

#[derive(Debug, Clone, Default)]
/// Tracks cached, current, total input, and output token counts.
pub struct TokenCacheManager {
    previous_chat_history: Vec<(String, String)>,
    previous_history_token_count: i64,
    cached_input_token_count: i64,
    current_input_token_count: i64,
    output_token_count: i64,
}

impl TokenCacheManager {
    /// Creates an empty token counter.
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns input tokens served from provider cache.
    pub fn cached_input_token_count(&self) -> i64 {
        self.cached_input_token_count
    }

    /// Returns non-cached input tokens for the current request.
    pub fn current_input_token_count(&self) -> i64 {
        self.current_input_token_count
    }

    /// Returns total input tokens for the current request.
    pub fn total_input_token_count(&self) -> i64 {
        self.cached_input_token_count + self.current_input_token_count
    }

    /// Returns output tokens counted for the current response.
    pub fn output_token_count(&self) -> i64 {
        self.output_token_count
    }

    /// Resets per-request token counters while retaining previous history for prefix cache matching.
    pub fn reset_token_counts(&mut self) {
        self.cached_input_token_count = 0;
        self.current_input_token_count = 0;
        self.output_token_count = 0;
    }

    /// Adds output tokens to the current response count.
    pub fn add_output_tokens(&mut self, tokens: i64) {
        self.output_token_count += tokens;
    }

    /// Replaces the output token count.
    pub fn set_output_tokens(&mut self, tokens: i64) {
        self.output_token_count = tokens;
    }

    /// Updates measured input token counts reported by a provider.
    pub fn update_actual_tokens(&mut self, actual_input: i64, cached_input: i64) {
        if cached_input > 0 {
            self.current_input_token_count = actual_input;
            self.cached_input_token_count = cached_input;
        } else if self.cached_input_token_count > 0 {
            let total_estimated = self.cached_input_token_count + self.current_input_token_count;
            if total_estimated > 0 && actual_input > 0 {
                let ratio = (actual_input as f64) / (total_estimated as f64);
                let scaled_cached =
                    ((self.cached_input_token_count as f64) * ratio).round() as i64;
                self.cached_input_token_count = scaled_cached.clamp(0, actual_input);
                self.current_input_token_count =
                    (actual_input - self.cached_input_token_count).max(0);
            } else {
                self.current_input_token_count = actual_input;
            }
        } else {
            self.current_input_token_count = actual_input;
        }
        self.previous_history_token_count =
            self.cached_input_token_count + self.current_input_token_count;
        let _ = AppLogger::w(
            "TokenCacheManager",
            &format!(
                "update_actual actual_input={} cached_input={} -> cached={} current={} prevTotal={} doubleCounted={}",
                actual_input,
                cached_input,
                self.cached_input_token_count,
                self.current_input_token_count,
                self.previous_history_token_count,
                cached_input > 0
            ),
        );
    }

    /// Estimates input tokens from chat message content.
    pub fn calculate_input_tokens(
        &mut self,
        chat_history: &[(String, String)],
        tools_json: Option<&str>,
        update_state: bool,
    ) -> i64 {
        let history_with_tools = history_with_tools(chat_history, tools_json);
        let common_prefix_length =
            find_common_prefix_length(&history_with_tools, &self.previous_chat_history);

        let (cached_tokens, new_tokens) = if common_prefix_length > 0 {
            let cached_tokens = if common_prefix_length == self.previous_chat_history.len() {
                self.previous_history_token_count
            } else {
                calculate_tokens_for_history(&history_with_tools[..common_prefix_length])
            };
            let new_tokens =
                calculate_tokens_for_history(&history_with_tools[common_prefix_length..]);
            (cached_tokens, new_tokens)
        } else {
            (0, calculate_tokens_for_history(&history_with_tools))
        };

        // 必须在 previous_chat_history 取走 history_with_tools 之前统计，
        // 否则后面对 history_with_tools 的任何借用都会触发 E0382。
        let totalChars: usize = history_with_tools
            .iter()
            .map(|(_, content)| content.chars().count())
            .sum();
        let systemChars = history_with_tools
            .iter()
            .find(|(role, _)| role == "system")
            .map(|(_, content)| content.chars().count())
            .unwrap_or(0);
        // 同理 len() 也必须提前取：随后的 previous_chat_history 赋值会把
        // history_with_tools move 走，之后再借用就是 E0382。
        let cur_hist_len = history_with_tools.len();
        if update_state {
            self.cached_input_token_count = cached_tokens;
            self.current_input_token_count = new_tokens;
            self.previous_history_token_count = cached_tokens + new_tokens;
            if !chat_history.is_empty() {
                self.previous_chat_history = history_with_tools;
            }
            let _ = AppLogger::w(
                "TokenCacheManager",
                &format!(
                    "calculate_input_tokens cached={} new={} total={} commonPrefix={} prevHistLen={} curHistLen={} prevTokenCount={} fullReuse={}",
                    cached_tokens,
                    new_tokens,
                    cached_tokens + new_tokens,
                    common_prefix_length,
                    self.previous_chat_history.len(),
                    cur_hist_len,
                    self.previous_history_token_count,
                    common_prefix_length == self.previous_chat_history.len()
                ),
            );
        }

        let total = cached_tokens + new_tokens;
        let _ = AppLogger::w(
            "TokenCacheManager",
            &format!(
                "estimate updateState={} cached={} new={} total={} commonPrefix={} prevHistLen={} curHistLen={} totalChars={} systemChars={}",
                update_state,
                cached_tokens,
                new_tokens,
                total,
                common_prefix_length,
                self.previous_chat_history.len(),
                cur_hist_len,
                totalChars,
                systemChars
            ),
        );
        total
    }
}

fn history_with_tools(
    chat_history: &[(String, String)],
    tools_json: Option<&str>,
) -> Vec<(String, String)> {
    let Some(tools) = tools_json.filter(|value| !value.is_empty()) else {
        return chat_history.to_vec();
    };
    let mut history = chat_history.to_vec();
    if let Some(index) = history.iter().position(|(role, _)| role == "system") {
        let (role, content) = &history[index];
        history[index] = (role.clone(), format!("{tools}\n{content}"));
    } else {
        history.insert(0, ("system".to_string(), tools.to_string()));
    }
    history
}

fn find_common_prefix_length(current: &[(String, String)], previous: &[(String, String)]) -> usize {
    let mut common = 0;
    for (left, right) in current.iter().zip(previous.iter()) {
        if left == right {
            common += 1;
        } else {
            break;
        }
    }
    common
}

fn calculate_tokens_for_history(history: &[(String, String)]) -> i64 {
    history
        .iter()
        .map(|(_, content)| ChatUtils::estimate_token_count(content))
        .sum()
}
