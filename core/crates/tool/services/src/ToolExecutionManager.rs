use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use std::future::Future;

use serde::{Deserialize, Serialize};

use operit_tools::tools::climode::CliToolModeSupport::{
    CliToolModeSupport, PROXY_TOOL_NAME, SEARCH_TOOL_NAME,
};
use operit_tools::tools::packTool::RuntimePackageManager::RuntimePackageManager;
use operit_tools::tools::AIToolHandler::AIToolHandler;
use operit_tools::tools::ToolResultDataClasses::stringResultData;
use operit_tools::ConversationMarkupManager::{ConversationMarkupManager, ToolResult};
use operit_util::AppLogger::AppLogger;
use operit_util::ChatMarkupRegex::{attr_value, tag_ranges, ChatMarkupRegex};

const TAG: &str = "ToolExecutionManager";
const PACKAGE_PROXY_TOOL_NAME: &str = "package_proxy";
const CLI_PROXY_TOOL_NAME: &str = PROXY_TOOL_NAME;
const CLI_SEARCH_TOOL_NAME: &str = SEARCH_TOOL_NAME;
const PACKAGE_CALLER_NAME_PARAM: &str = "__operit_package_caller_name";
const PACKAGE_CHAT_ID_PARAM: &str = "__operit_package_chat_id";
const PACKAGE_CALLER_PARTICIPANT_ID_PARAM: &str = "__operit_package_caller_participant_id";
const PACKAGE_CALLER_OWNER_PARAM: &str = "__operit_package_caller_owner";

tokio::task_local! {
    static TOOL_RUNTIME_CONTEXT: ToolRuntimeContext;
    static TOOL_INVOCATION_CONTEXT: ToolInvocationContext;
}

/// Selects the tool surface available to a model response.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ToolExposureMode {
    /// Native tool-call markup with the full registered tool catalog.
    FULL,
    /// Command-line proxy mode with a restricted public tool surface.
    CLI,
}

/// Context made available while a batch of tool invocations is executing.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolRuntimeContext {
    pub callerChatId: Option<String>,
    pub callerParticipantId: Option<String>,
    pub workspacePath: Option<String>,
    pub workspaceFolders: Vec<String>,
    pub toolExposureMode: ToolExposureMode,
    /// Identifies the native-authenticated configuration owner captured for this execution.
    pub extensionOwner: String,
    /// Preserves current execution data for the active turn; never persisted on a message.
    pub executionData: serde_json::Map<String, serde_json::Value>,
}

impl ToolRuntimeContext {
    /// A real workspace takes precedence over the chat's persistent output area.
    pub fn fileDirectory(&self, storage: Arc<dyn operit_host_api::RuntimeStorageHost>) -> Result<Option<String>, String> {
        if let Some(path) = self.workspacePath.as_ref().filter(|path| !path.trim().is_empty()) {
            return Ok(Some(path.clone()));
        }
        match self.callerChatId.as_deref() {
            Some(id) => operit_store::ChatOutputStore::ChatOutputStore::new(storage).prepare(id),
            None => Ok(None),
        }
    }

    /// Rejects unauthenticated or malformed turn identities before entering any policy dispatch.
    pub fn validateExecutionContext(&self) -> Result<(), String> {
        if self.extensionOwner.trim().is_empty()
            || self.extensionOwner.trim() != self.extensionOwner
        {
            return Err("Tool execution context requires an exact authenticated extensionOwner".to_string());
        }
        for (field, value) in [
            ("chatId", self.callerChatId.as_deref()),
            ("participantId", self.callerParticipantId.as_deref()),
        ] {
            if let Some(value) = value {
                if value.trim().is_empty() || value.trim() != value {
                    return Err(format!("Tool execution context {field} must be exact nonblank text"));
                }
            }
        }
        Ok(())
    }
}

/// Name-value parameter parsed from a model tool invocation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolParameter {
    pub name: String,
    pub value: String,
}

/// Parsed model request for one AI tool invocation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AITool {
    pub name: String,
    pub parameters: Vec<ToolParameter>,
}

/// Preserves structured parameters through the common invocation pipeline.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ToolCall {
    pub name: String,
    pub parameters: BTreeMap<String, serde_json::Value>,
}

/// Guard against a hostile or cyclic envelope; real calls nest only a handful of times.
const MAX_ENVELOPE_DEPTH: usize = 32;


impl ToolCall {
    /// Resolves an explicit proxy envelope before the sole lifecycle runs.
    ///
    /// Models routinely target the proxy itself (`tool_name` = `package_proxy`) and nest the real
    /// call one level down, so the inner envelope is unwrapped and re-resolved. When the target
    /// cannot be recovered the call fails with one actionable sentence instead of internal jargon.
    pub(crate) fn resolveTarget(&self, context: &ToolInvocationContext) -> Result<Self, String> {
        if !matches!(self.name.as_str(), PACKAGE_PROXY_TOOL_NAME | CLI_PROXY_TOOL_NAME) { return Ok(self.clone()); }
        if self.name == CLI_PROXY_TOOL_NAME && context.turnSnapshot().map(|turn| &turn.toolExposureMode) != Some(&ToolExposureMode::CLI) {
            return Err(CliToolModeSupport::buildCliModeUnavailableMessage(false));
        }
        self.resolveProxyEnvelope()
    }

    /// Context-free half of `resolveTarget`, so the envelope rules can be unit tested.
    ///
    /// The transport re-wraps a proxy call once per hop, so a single logical call can arrive with
    /// the real target buried several `params` levels deep. The target is therefore searched all
    /// the way down instead of at a fixed depth.
    fn resolveProxyEnvelope(&self) -> Result<Self, String> {
        let Some((name, arguments)) = Self::deepestProxyTarget(&self.parameters, 0) else {
            return Err(self.nestedProxyAdvice());
        };
        // 目录入口（search）不是可调用工具，单独说清楚。
        if !matches!(name.as_str(), PACKAGE_PROXY_TOOL_NAME | CLI_PROXY_TOOL_NAME)
            && CliToolModeSupport::isReservedProxyTarget(&name)
        {
            return Err(format!(
                "`{name}` is a catalog entry, not a callable tool. Pass the concrete package tool instead, e.g. package_proxy {{\"tool_name\":\"<packageName>:<toolName>\",\"params\":{{...}}}}."
            ));
        }
        // 整棵树里只有 proxy 自己，没有真目标。
        if matches!(name.as_str(), PACKAGE_PROXY_TOOL_NAME | CLI_PROXY_TOOL_NAME) {
            return Err(self.nestedProxyAdvice());
        }
        self.finishProxyResolution(&name, arguments)
    }

    /// Descends through every `params` layer and returns the innermost callable target with its
    /// arguments. Outer argument keys survive unless the inner envelope overrides them.
    fn deepestProxyTarget(
        parameters: &BTreeMap<String, serde_json::Value>,
        depth: usize,
    ) -> Option<(String, BTreeMap<String, serde_json::Value>)> {
        if depth > MAX_ENVELOPE_DEPTH {
            return None;
        }
        let nested = parameters
            .get("params")
            .and_then(Self::paramsObjectOf)
            .and_then(|object| Self::deepestProxyTarget(&object, depth + 1))
            // provider 会把参数整体包进 arguments / input / args / kwargs / parameters。
            .or_else(|| {
                proxyArgumentWrapperKeys().iter().find_map(|key| {
                    parameters
                        .get(*key)
                        .and_then(Self::paramsObjectOf)
                        .and_then(|object| Self::deepestProxyTarget(&object, depth + 1))
                })
            });
        if let Some((name, arguments)) = nested {
            let mut merged = Self::argumentsAt(parameters);
            for (key, value) in arguments {
                merged.insert(key, value);
            }
            return Some((name, merged));
        }
        let name = Self::proxyNameAt(parameters)?;
        Some((name, Self::argumentsAt(parameters)))
    }

    /// Parses a `params` value that may be an object, a JSON string, or XML-escaped JSON.
    fn paramsObjectOf(value: &serde_json::Value) -> Option<BTreeMap<String, serde_json::Value>> {
        match value {
            serde_json::Value::Object(object) => Some(object.clone().into_iter().collect()),
            serde_json::Value::String(text) => {
                let unescaped = ToolExecutionManager::unescapeXml(text);
                serde_json::from_str::<serde_json::Value>(&unescaped)
                    .ok()
                    .or_else(|| serde_json::from_str::<serde_json::Value>(text).ok())
                    .and_then(|parsed| match parsed {
                        serde_json::Value::Object(object) => {
                            Some(object.into_iter().collect::<BTreeMap<_, _>>())
                        }
                        _ => None,
                    })
            }
            _ => None,
        }
    }

    /// Reads a nonblank `tool_name` from one flat parameter map without descending.
    fn proxyNameAt(parameters: &BTreeMap<String, serde_json::Value>) -> Option<String> {
        parameters
            .get("tool_name")
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .map(str::to_string)
    }

    /// Collects the target arguments carried by one envelope layer, dropping envelope-only keys.
    fn argumentsAt(parameters: &BTreeMap<String, serde_json::Value>) -> BTreeMap<String, serde_json::Value> {
        let mut arguments = parameters
            .iter()
            .filter(|(key, _)| {
                !matches!(key.as_str(), "tool_name" | "params")
                    && !key.starts_with("__operit_package_")
            })
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect::<BTreeMap<_, _>>();
        if let Some(inner) = parameters.get("params").and_then(Self::paramsObjectOf) {
            for (key, value) in inner {
                if matches!(key.as_str(), "tool_name" | "params") || key.starts_with("__operit_package_") {
                    continue;
                }
                arguments.entry(key).or_insert(value);
            }
        }
        // 各家 provider 对「目标工具参数」的字段名并不统一，只剩一个包装对象时它的成员才是真参数。
        unwrapProxyArgumentWrapper(arguments)
    }

    /// Echo of the parameter shape that actually arrived, so a caller can self-correct.
    fn receivedArgumentsDump(&self) -> String {
        let mut received = self
            .parameters
            .iter()
            .filter(|(key, _)| !key.starts_with("__operit_package_"))
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect::<BTreeMap<_, _>>();
        if let Some(serde_json::Value::String(text)) = received.get("params").cloned() {
            let unescaped = ToolExecutionManager::unescapeXml(&text);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&unescaped) {
                received.insert("params".to_string(), parsed);
            }
        }
        let mut dump = serde_json::Value::Object(received.into_iter().collect()).to_string();
        if dump.chars().count() > 400 {
            dump = dump.chars().take(400).collect::<String>() + "...";
        }
        dump
    }

    /// One actionable sentence plus the parameter shape that actually arrived.
    fn nestedProxyAdvice(&self) -> String {
        format!(
            "Package proxy could not resolve a real target. Received arguments: {}. Call the concrete tool directly once: package_proxy {{\"tool_name\":\"<packageName>:<toolName>\",\"params\":{{...}}}}. Never put package_proxy, proxy or search in tool_name.",
            self.receivedArgumentsDump()
        )
    }

    /// Builds the final target call: validates the name shape and flattens the argument object.
    fn finishProxyResolution(&self, name: &str, arguments: BTreeMap<String, serde_json::Value>) -> Result<Self, String> {
        if name.trim().is_empty() || name.trim() != name { return Err("Proxy tool_name must be exact nonblank text".into()); }
        if self.name == PACKAGE_PROXY_TOOL_NAME {
            match name.split_once(':') {
                Some((package, method)) if !package.is_empty() && !method.is_empty() && !method.contains(':') => {},
                _ => return Err("tool_name must use packageName:toolName format".into()),
            }
        }
        // 信封字段不能漏进目标工具，否则会被判成 `Unknown tool parameter`。
        let mut parameters = arguments;
        // 调用方身份由宿主注入，必须原样带到目标工具，否则 JS 工具拿不到调用上下文。
        for key in [PACKAGE_CALLER_NAME_PARAM, PACKAGE_CHAT_ID_PARAM, PACKAGE_CALLER_PARTICIPANT_ID_PARAM, PACKAGE_CALLER_OWNER_PARAM] {
            parameters.remove(key);
            if let Some(value) = self.parameters.get(key) { parameters.insert(key.to_string(), value.clone()); }
        }
        Ok(Self { name: name.to_string(), parameters })
    }

    /// Parses the envelope's `params` into an object, tolerating the legacy text encoding.
    fn proxyParamsObject(&self) -> Result<serde_json::Map<String, serde_json::Value>, String> {
        match self.parameters.get("params") {
            None | Some(serde_json::Value::Null) => Ok(serde_json::Map::new()),
            Some(serde_json::Value::String(text)) => {
                // 模型从 XML 形式给出参数时，引号会被转义成 " / ' 等。
                // 不先还原就解析 JSON 必然失败，表现为
                // 「Tool request contains a non-JSON value」（crossref 这类严格校验的工具首当其冲）。
                let unescaped = ToolExecutionManager::unescapeXml(text);
                match serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(&unescaped) {
                    Ok(object) => Ok(object),
                    // 还原后仍失败时退回原文解析，兼容调用方直接传真实 JSON 的情况。
                    Err(_) => serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(text)
                        .map_err(|error| error.to_string()),
                }
            }
            Some(serde_json::Value::Object(object)) => Ok(object.clone()),
            Some(_) => Err("Proxy params must be a JSON object or its legacy text encoding".into()),
        }
    }

    /// Adapts values only at the legacy executor and text-hook contract boundary.
    pub fn toLegacyTool(&self) -> AITool {
        AITool {
            name: self.name.clone(),
            parameters: self.parameters.iter().map(|(name, value)| ToolParameter {
                name: name.clone(),
                value: match value {
                    serde_json::Value::String(text) => text.clone(),
                    value => value.to_string(),
                },
            }).collect(),
        }
    }
}

impl From<&AITool> for ToolCall {
    /// Adapts model text without interpreting its contents as JSON or caller identity.
    fn from(tool: &AITool) -> Self {
        Self {
            name: tool.name.clone(),
            parameters: tool.parameters.iter().map(|parameter| (
                parameter.name.clone(), serde_json::Value::String(parameter.value.clone()),
            )).collect(),
        }
    }
}

/// Carries native-owned caller state independently of public tool parameters and shared registrations.
#[derive(Clone)]
pub struct ToolInvocationContext {
    host: AIToolHandler,
    snapshot: ToolInvocationSnapshot,
}

/// Captures transport-independent turn and hook state before any Host scheduling boundary.
#[derive(Clone, Default)]
pub(crate) struct ToolInvocationSnapshot {
    pub turnSnapshot: Option<ToolRuntimeContext>,
    activeHooks: BTreeSet<String>,
}

impl ToolInvocationContext {
    /// Captures the actual caller-bound handler, turn snapshot and inherited hook scope.
    pub(crate) fn capture(host: AIToolHandler) -> Self {
        let snapshot = match TOOL_INVOCATION_CONTEXT.try_with(|context| context.snapshot.clone()) {
            Ok(snapshot) => snapshot,
            Err(_) => match TOOL_RUNTIME_CONTEXT.try_with(Clone::clone) {
                Ok(turn) => ToolInvocationSnapshot { turnSnapshot: Some(turn), activeHooks: BTreeSet::new() },
                Err(_) => host.invocationSnapshot.clone(),
            },
        };
        Self { host, snapshot }
    }

    /// Clones the immutable snapshot for transfer to an engine-bound native host.
    pub(crate) fn snapshot(&self) -> ToolInvocationSnapshot { self.snapshot.clone() }

    /// Borrows the immutable caller-bound handler carrying its authenticated owner and storage session.
    pub fn host(&self) -> &AIToolHandler { &self.host }

    /// Requires the immutable engine-bound owner to remain registered and enabled.
    pub fn requirePluginOwner(&self) -> Result<String, String> {
        let owner = self.host.authenticatedExtensionOwner.as_deref()
            .ok_or_else(|| "Plugin operations require a real ToolPkg execution owner".to_string())?;
        if owner.trim().is_empty() || owner.trim() != owner { return Err("Plugin execution owner is not exact nonblank text".into()); }
        let manager = self.host.getOrCreatePackageManager();
        let registry = manager.lock().map_err(|_| "Package manager mutex poisoned")?;
        registry.requireEnabledToolPkgContainer(owner)?;
        Ok(owner.to_string())
    }

    /// Borrows the exact captured model turn independently of the executing plugin's ownership.
    pub fn turnSnapshot(&self) -> Option<&ToolRuntimeContext> { self.snapshot.turnSnapshot.as_ref() }

    /// Returns whether this invocation is already executing the named hook.
    pub fn isHookActive(&self, id: &str) -> bool { self.snapshot.activeHooks.contains(id) }

    /// Captures a nested scope before awaiting the named hook.
    pub fn withHook(&self, id: &str) -> Self {
        let mut nested = self.clone();
        nested.snapshot.activeHooks.insert(id.to_owned());
        nested
    }

    /// Reinstalls native caller state for synchronous hook dispatch and cancellation cleanup.
    pub fn scopeSync<T>(self, action: impl FnOnce() -> T) -> T {
        let turn = self.snapshot.turnSnapshot.clone();
        let scoped = || TOOL_INVOCATION_CONTEXT.sync_scope(self, action);
        match turn {
            Some(turn) => TOOL_RUNTIME_CONTEXT.sync_scope(turn, scoped),
            None => scoped(),
        }
    }

    /// Keeps native caller state available throughout this asynchronous invocation.
    pub async fn scope<T, F: Future<Output = T>>(self, future: F) -> T {
        let turn = self.snapshot.turnSnapshot.clone();
        let scoped = TOOL_INVOCATION_CONTEXT.scope(self, future);
        match turn {
            Some(turn) => TOOL_RUNTIME_CONTEXT.scope(turn, scoped).await,
            None => scoped.await,
        }
    }
}

/// Parsed tool invocation plus its source text location in the assistant response.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolInvocation {
    pub tool: AITool,
    pub rawText: String,
    pub responseLocation: (usize, usize),
}

/// Captures a completed request to move one chat to another CoreNode.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RouteChangeIntent {
    pub targetNodeId: String,
}

/// Owns finalized results and separate display and provider projections.
pub struct ToolExecutionBatch {
    pub results: Vec<ToolResult>,
    pub message: String,
    pub displayMessage: String,
    pub routeChangeIntent: Option<RouteChangeIntent>,
}

impl ToolExecutionBatch {
    /// Formats each invocation result once without imposing a batch-wide output limit.
    pub fn new(results: Vec<ToolResult>, routeChangeIntent: Option<RouteChangeIntent>) -> Self {
        let message = ConversationMarkupManager::buildToolResultMessage(&results);
        let displayMessage = results.iter()
            .map(|result| ConversationMarkupManager::formatToolResultForDisplay(result, None))
            .collect::<Vec<_>>().join("\n");
        Self { results, message, displayMessage, routeChangeIntent }
    }
}

/// Parses model tool calls, checks permissions, and executes tools through handlers.
pub struct ToolExecutionManager;

/// Selects native-owned admission policy without exposing permission controls to JavaScript parameters.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ToolExecutionPolicy {
    /// Dispatches AI lifecycle hooks and applies the model's declared exposure and permission preflight.
    Ai { exposure: ToolExposureMode },
    /// Executes an ordinary JavaScript or application request without AI lifecycle hooks or permission preflight.
    Direct,
}

/// Names the wrapper keys that providers use for a tool call's real arguments.
fn proxyArgumentWrapperKeys() -> [&'static str; 6] {
    ["arguments", "args", "kwargs", "parameters", "input", "arguments_json"]
}

/// Parses a wrapper value that may be a JSON object or its text encoding.
fn proxyArgumentWrapperObject(value: &serde_json::Value) -> Option<serde_json::Map<String, serde_json::Value>> {
    match value {
        serde_json::Value::Object(object) => Some(object.clone()),
        serde_json::Value::String(text) => {
            let unescaped = ToolExecutionManager::unescapeXml(text);
            serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(&unescaped)
                .or_else(|_| serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(text))
                .ok()
        }
        _ => None,
    }
}

/// Recovers `tool_name` nested inside a provider-style argument wrapper.
fn proxyWrapperToolName(parameters: &BTreeMap<String, serde_json::Value>) -> Option<String> {
    for key in proxyArgumentWrapperKeys() {
        let Some(value) = parameters.get(key) else { continue };
        let Some(object) = proxyArgumentWrapperObject(value) else { continue };
        if let Some(text) = object.get("tool_name").and_then(serde_json::Value::as_str) {
            if !text.trim().is_empty() {
                return Some(text.to_string());
            }
        }
    }
    None
}

/// Unwraps a lone `arguments`/`input`/`args` object into the target tool's real parameters.
///
/// Provider formats disagree on where arguments live, and a wrapped call otherwise fails
/// every required-parameter check. Only a single wrapper key at the top of the envelope is
/// unwrapped, so a genuine business parameter that happens to share the name is untouched.
fn unwrapProxyArgumentWrapper(
    parameters: BTreeMap<String, serde_json::Value>,
) -> BTreeMap<String, serde_json::Value> {
    let mut current = parameters;
    // Three rounds cover `{"arguments":{"input":{...}}}` without risking an endless loop.
    for _ in 0..3 {
        if current.len() != 1 {
            break;
        }
        let Some(key) = current.keys().next().cloned() else { break };
        if !proxyArgumentWrapperKeys().contains(&key.as_str()) {
            break;
        }
        let Some(value) = current.get(&key) else { break };
        let Some(object) = proxyArgumentWrapperObject(value) else { break };
        current = object.into_iter().collect();
    }
    current
}

impl ToolExecutionManager {
    /// Returns the native context captured for the current invocation and its awaited hooks.
    pub fn currentToolInvocationContext() -> Option<ToolInvocationContext> {
        TOOL_INVOCATION_CONTEXT.try_with(Clone::clone).ok()
    }

    /// Returns the runtime context for the currently executing tool batch.
    pub fn currentToolRuntimeContext() -> Option<ToolRuntimeContext> {
        TOOL_RUNTIME_CONTEXT.try_with(Clone::clone).ok()
    }

    /// Scopes an owned turn snapshot to one asynchronous execution, including every awaited hook.
    pub async fn scopeToolRuntimeContext<T, F>(context: ToolRuntimeContext, future: F) -> T
    where
        F: Future<Output = T>,
    {
        TOOL_RUNTIME_CONTEXT.scope(context, future).await
    }

    /// Extracts XML-like tool invocations from an assistant response.
    pub fn extractToolInvocations(response: &str) -> Vec<ToolInvocation> {
        let mut invocations = Vec::new();
        for tool_match in ChatMarkupRegex::tool_call_matches(response) {
            let mut parameters = Vec::new();
            for (start, end) in tag_ranges(&tool_match.body, "param") {
                let raw = &tool_match.body[start..end];
                let paramName = attr_value(raw, "name").unwrap_or_default();
                let paramValue = raw
                    .split_once('>')
                    .and_then(|(_, tail)| tail.rsplit_once("</").map(|(body, _)| body))
                    .map(Self::unescapeXml)
                    .unwrap_or_default();
                parameters.push(ToolParameter {
                    name: paramName,
                    value: paramValue,
                });
            }
            // 模型自创写法用 `<parameter=key>value</parameter>`（等号形式），
            // 标准写法才是 `<param name="key">value</param>`。前者在 tag_ranges 里
            // 一个都匹配不到，参数就全空了 —— 空参数的调用往往会失败，进而让整轮停住。
            if parameters.is_empty() {
                parameters = Self::extractLooseParameters(&tool_match.body);
            }
            invocations.push(ToolInvocation {
                tool: AITool {
                    name: tool_match.name,
                    parameters,
                },
                rawText: response[tool_match.start..tool_match.end].to_string(),
                responseLocation: (tool_match.start, tool_match.end),
            });
        }
        let toolNames = invocations
            .iter()
            .map(|invocation| invocation.tool.name.clone())
            .collect::<Vec<_>>()
            .join(", ");
        AppLogger::v_with_level(
            TAG,
            &format!(
                "tool.parse.complete responseChars={} toolCount={} tools=[{}]",
                response.len(),
                invocations.len(),
                toolNames
            ),
            operit_util::AppLogger::VERBOSE_LEVEL_3,
        );
        invocations
    }

    /// 解析 `<parameter=key>value` / `<param=key>value` 这种等号写法。
    ///
    /// 值取到下一个参数标记为止（与模型的平铺写法一致），并做 XML 反转义。
    fn extractLooseParameters(body: &str) -> Vec<ToolParameter> {
        const MARKERS: [&str; 2] = ["<parameter=", "<param="];
        let mut opens: Vec<(usize, usize)> = Vec::new();
        for marker in MARKERS {
            let mut from = 0usize;
            while let Some(relative) = body[from..].find(marker) {
                let absolute = from + relative;
                opens.push((absolute, marker.len()));
                from = absolute + marker.len();
            }
        }
        opens.sort_by_key(|(position, _)| *position);

        let mut parameters = Vec::new();
        for (index, (start, markerLen)) in opens.iter().enumerate() {
            let after = &body[start + markerLen..];
            let Some(keyEnd) = after.find('>') else { continue };
            let key = after[..keyEnd].trim().trim_matches('"').trim().to_string();
            if key.is_empty() {
                continue;
            }
            let valueStart = start + markerLen + keyEnd + 1;
            let valueEnd = opens
                .get(index + 1)
                .map(|(position, _)| *position)
                .unwrap_or(body.len());
            if valueStart > valueEnd {
                continue;
            }
            let value = Self::unescapeXml(&body[valueStart..valueEnd])
                .trim()
                .to_string();
            parameters.push(ToolParameter { name: key, value });
        }
        parameters
    }

    /// Executes a serial batch and finalizes one shared display/history result per invocation.
    pub async fn executeInvocations(
        invocations: &[ToolInvocation],
        toolHandler: &mut AIToolHandler,
        packageManager: &RuntimePackageManager,
        callerName: Option<String>,
        callerChatId: Option<String>,
        callerParticipantId: Option<String>,
        workspacePath: Option<String>,
        workspaceFolders: Vec<String>,
        toolExposureMode: ToolExposureMode,
        extensionOwner: String,
        executionData: serde_json::Map<String, serde_json::Value>,
    ) -> Result<ToolExecutionBatch, String> {
        let runtimeContext = ToolRuntimeContext {
            callerChatId: callerChatId.clone(),
            callerParticipantId: callerParticipantId.clone(),
            workspacePath: workspacePath.clone(),
            workspaceFolders: workspaceFolders.clone(),
            toolExposureMode: toolExposureMode.clone(),
            extensionOwner,
            executionData,
        };
        runtimeContext.validateExecutionContext()?;
        Self::scopeToolRuntimeContext(runtimeContext, async move {
        let mut results = Vec::new();
        let mut displays = Vec::new();
        let mut routeChangeIntent = None;
        let requestedToolNames = invocations
            .iter()
            .map(|invocation| invocation.tool.name.clone())
            .collect::<Vec<_>>()
            .join(", ");
        AppLogger::v_with_level(
            TAG,
            &format!(
                "tool.execution.batch_start requestedCount={} tools=[{}] callerNameSet={} callerChatIdSet={} callerParticipantIdSet={} exposure={:?}",
                invocations.len(),
                requestedToolNames,
                callerName.is_some(),
                callerChatId.is_some(),
                callerParticipantId.is_some(),
                toolExposureMode
            ),
            operit_util::AppLogger::VERBOSE_LEVEL_3,
        );
        toolHandler.registerDefaultTools();
        let jsPackageNames = packageManager
            .getAvailablePackages()
            .keys()
            .cloned()
            .collect::<BTreeSet<_>>();
        let injectedInvocations = invocations
            .iter()
            .map(|invocation| {
                Self::injectPackageCallContext(
                    invocation,
                    &jsPackageNames,
                    callerName.as_deref(),
                    callerChatId.as_deref(),
                    callerParticipantId.as_deref(),
                )
            })
            .collect::<Vec<_>>();

        for invocation in injectedInvocations.iter().cloned() {
            let displayToolName = Self::resolveDisplayToolName(&invocation.tool);
            AppLogger::trace_detail(
                TAG,
                &format!(
                    "tool.execution.start tool={} params={} rawBytes={}",
                    displayToolName,
                    invocation.tool.parameters.len(),
                    invocation.rawText.len()
                ),
            );
            let collected = toolHandler
                .executeToolInvocation(
                    &ToolCall::from(&invocation.tool),
                    ToolExecutionPolicy::Ai { exposure: toolExposureMode.clone() },
                )
                .await?;
            AppLogger::v_with_level(
                TAG,
                &format!(
                    "tool.execution.raw_results tool={} rawResultCount={}",
                    displayToolName,
                    collected.len()
                ),
                operit_util::AppLogger::VERBOSE_LEVEL_3,
            );
            {
                let last = collected.last().expect("collected not empty");
                let combinedResultString = collected
                    .iter()
                    .map(|item| {
                        if item.success {
                            item.result.toString().trim().to_string()
                        } else {
                            format!(
                                "Step error: {}",
                                item.error
                                    .clone()
                                    .unwrap_or_else(|| "Unknown error".to_string())
                            )
                        }
                    })
                    .collect::<Vec<_>>()
                    .join("\n")
                    .trim()
                    .to_string();
                let finalResult = ToolResult {
                    toolName: displayToolName.clone(),
                    success: last.success,
                    result: if collected.len() == 1 {
                        last.result.clone()
                    } else {
                        stringResultData(combinedResultString)
                    },
                    error: last.error.clone(),
                };
                if let Some(intent) = Self::routeChangeIntentForResult(&invocation.tool, last) {
                    routeChangeIntent = Some(intent);
                }
                AppLogger::v_with_level(
                    TAG,
                    &format!(
                        "tool.execution.complete tool={} success={} rawResultCount={} combinedBytes={}",
                        displayToolName,
                        finalResult.success,
                        collected.len(),
                        finalResult.result.toString().len()
                    ),
                    operit_util::AppLogger::VERBOSE_LEVEL_3,
                );
                displays.push(toolHandler.toolDisplayDeclaration(&displayToolName));
                results.push(finalResult);
            }
        }

        let mut batch = ToolExecutionBatch::new(results, routeChangeIntent);
        batch.displayMessage = batch.results.iter().zip(&displays)
            .map(|(result, display)| ConversationMarkupManager::formatToolResultForDisplay(result, display.as_ref()))
            .collect::<Vec<_>>().join("\n");
        AppLogger::v_with_level(
            TAG,
            &format!(
                "tool.execution.batch_complete requestedCount={} resultCount={} messageBytes={}",
                invocations.len(),
                batch.results.len(),
                batch.message.len()
            ),
            operit_util::AppLogger::VERBOSE_LEVEL_3,
        );
        Ok(batch)
        }).await
    }

    /// Builds a route-change intent from the successful switch_core tool result.
    #[allow(non_snake_case)]
    fn routeChangeIntentForResult(tool: &AITool, result: &ToolResult) -> Option<RouteChangeIntent> {
        if Self::resolveDisplayToolName(tool).trim() != "switch_core"
            || result.toolName.trim() != "switch_core"
            || !result.success
        {
            return None;
        }
        Some(RouteChangeIntent {
            targetNodeId: result.result.toString().trim().to_string(),
        })
    }

    /// Returns only a presentation name; execution arguments are resolved strictly by ToolCall.
    fn resolveDisplayToolName(tool: &AITool) -> String {
        match tool.name.as_str() {
            PACKAGE_PROXY_TOOL_NAME | CLI_PROXY_TOOL_NAME => {
                match tool.parameters.iter().find(|parameter| parameter.name == "tool_name") {
                    Some(parameter) => parameter.value.clone(),
                    None => tool.name.clone(),
                }
            },
            _ => tool.name.clone(),
        }
    }

    fn isJsPackageTool(toolName: &str, jsPackageNames: &BTreeSet<String>) -> bool {
        let parts = toolName.splitn(2, ':').collect::<Vec<_>>();
        parts.len() == 2 && jsPackageNames.contains(parts[0])
    }

    /// Replaces every untrusted reserved value with the authenticated host context, including its absence.
    fn setPackageContextParameter(
        params: &mut Vec<ToolParameter>,
        name: &str,
        value: Option<&str>,
    ) {
        params.retain(|parameter| parameter.name != name);
        if let Some(value) = value {
            params.push(ToolParameter {
                name: name.to_string(),
                value: value.to_string(),
            });
        }
    }

    /// Injects canonical context into a selected JavaScript tool or its proxy wrapper.
    fn injectPackageCallContext(
        invocation: &ToolInvocation,
        jsPackageNames: &BTreeSet<String>,
        callerName: Option<&str>,
        callerChatId: Option<&str>,
        callerParticipantId: Option<&str>,
    ) -> ToolInvocation {
        let targetName = Self::resolveDisplayToolName(&invocation.tool);
        if !Self::isJsPackageTool(&targetName, jsPackageNames) {
            return invocation.clone();
        }

        let mut updatedParams = invocation.tool.parameters.clone();
        Self::setPackageContextParameter(&mut updatedParams, PACKAGE_CALLER_NAME_PARAM, callerName);
        Self::setPackageContextParameter(&mut updatedParams, PACKAGE_CHAT_ID_PARAM, callerChatId);
        Self::setPackageContextParameter(
            &mut updatedParams,
            PACKAGE_CALLER_PARTICIPANT_ID_PARAM,
            callerParticipantId,
        );

        let context = Self::currentToolRuntimeContext();
        Self::setPackageContextParameter(
            &mut updatedParams,
            PACKAGE_CALLER_OWNER_PARAM,
            context.as_ref().map(|context| context.extensionOwner.as_str()),
        );

        ToolInvocation {
            tool: AITool {
                name: invocation.tool.name.clone(),
                parameters: updatedParams,
            },
            rawText: invocation.rawText.clone(),
            responseLocation: invocation.responseLocation,
        }
    }

    fn getParameterValue(tool: &AITool, name: &str) -> Option<String> {
        tool.parameters
            .iter()
            .find(|parameter| parameter.name == name)
            .map(|parameter| parameter.value.trim().to_string())
    }

    /// Rejects tools outside the model surface before the common pipeline resolves an executor.
    pub(crate) fn buildToolExposureDeniedResult(
        tool: &AITool,
        toolExposureMode: ToolExposureMode,
    ) -> Option<ToolResult> {
        let toolName = tool.name.trim();
        let denied = match toolExposureMode {
            ToolExposureMode::CLI if !Self::isCliPublicTool(toolName) => Some(format!(
                "{}",
                CliToolModeSupport::buildCliTopLevelRestrictionErrorMessage(
                    &Self::resolveDisplayToolName(tool),
                    true,
                )
            )),
            ToolExposureMode::FULL if Self::isCliPublicTool(toolName) => {
                Some(CliToolModeSupport::buildCliModeUnavailableMessage(true))
            }
            _ => None,
        }?;

        Some(ToolResult {
            toolName: if toolExposureMode == ToolExposureMode::CLI
                && !Self::isCliPublicTool(toolName)
            {
                Self::resolveDisplayToolName(tool)
            } else {
                toolName.to_string()
            },
            success: false,
            result: stringResultData(""),
            error: Some(denied),
        })
    }

    fn isCliPublicTool(toolName: &str) -> bool {
        toolName == CLI_SEARCH_TOOL_NAME || toolName == CLI_PROXY_TOOL_NAME
    }

    fn buildToolNotAvailableErrorMessage(toolName: &str) -> String {
        if toolName.contains('.') && !toolName.contains(':') {
            let parts = toolName.splitn(2, '.').collect::<Vec<_>>();
            return format!(
                "Tool invocation syntax error: for tools inside a package, use the 'packName:toolName' format instead of '{}'. You may want to call '{}:{}'.",
                toolName,
                parts.get(0).copied().unwrap_or(""),
                parts.get(1).copied().unwrap_or("")
            );
        }

        if toolName.contains(':') {
            let parts = toolName.splitn(2, ':').collect::<Vec<_>>();
            let packName = parts[0];
            let toolNamePart = parts.get(1).copied().unwrap_or("");
            return format!(
                "Tool package '{}' is not activated. Auto-activation was attempted but failed, or tool '{}' does not exist. Please use 'use_package' with package name '{}' to check available tools.",
                packName, toolNamePart, packName
            );
        }

        format!(
            "Tool '{}' is unavailable or does not exist. If this is a tool inside a package, call it using the 'packName:toolName' format.",
            toolName
        )
    }

    pub(crate) fn unescapeXml(input: &str) -> String {
        let mut result = input.to_string();
        if result.starts_with("<![CDATA[") && result.ends_with("]]>") {
            result = result[9..result.len() - 3].to_string();
        }
        if result.ends_with("]]>") {
            result.truncate(result.len() - 3);
        }
        if result.starts_with("<![CDATA[") {
            result = result[9..].to_string();
        }
        result
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&amp;", "&")
            .replace("&quot;", "\"")
            .replace("&apos;", "'")
    }
}

/// Executes independent requests through immutable, concurrently shareable services.
pub trait ToolExecutor: Send + Sync {
    /// Validates one request without storing invocation state in the executor.
    fn validateParameters(&self, tool: &AITool) -> ToolValidationResult;
    /// Declares the request's resource boundary before execution.
    fn accessSpec(&self, tool: &AITool) -> Result<ToolAccessSpec, String>;
    /// Executes one request; resource-specific Host services own any required synchronization.
    fn invokeAndStream(&self, tool: &AITool) -> Vec<ToolResult>;
}

/// Represents a tool result produced without blocking its calling executor.
pub type ToolInvocationFuture<'a> =
    std::pin::Pin<Box<dyn std::future::Future<Output = Vec<ToolResult>> + Send + 'a>>;

/// Shares asynchronous services while each call retains its own arguments, context and future.
pub trait AsyncToolExecutor: Send + Sync {
    /// Validates a request before its execution begins.
    fn validateParameters(&self, tool: &AITool) -> ToolValidationResult;
    /// Declares the access boundary of the asynchronous tool.
    fn accessSpec(&self, tool: &AITool) -> Result<ToolAccessSpec, String>;
    /// Executes one invocation on its asynchronous result path.
    fn invokeAndStreamAsync<'a>(&'a self, tool: &'a AITool, context: &'a ToolInvocationContext) -> ToolInvocationFuture<'a>;
}

/// Holds one validated invocation and its optional native AI access declaration.
pub struct PreparedToolInvocation<'a> {
    pub access: Option<ToolAccessSpec>,
    pub invoke: ToolInvocationFuture<'a>,
}

/// Prepares typed concurrent operations without retaining mutable invocation state.
pub trait SharedToolExecutor: Send + Sync {
    /// Decodes and validates once, declaring access only when native AI admission requires it.
    fn prepare<'a>(&'a self, request: &'a ToolCall, context: &'a ToolInvocationContext, checkAccess: bool)
        -> Result<PreparedToolInvocation<'a>, String>;
}

/// Records the execution contract explicitly selected when a tool is registered.
pub enum RegisteredToolExecutor {
    /// Declares an invocation envelope resolved before execution, never an executable forwarding tool.
    Alias,
    Synchronous(Box<dyn ToolExecutor>),
    Asynchronous(Box<dyn AsyncToolExecutor>),
    Shared(Arc<dyn SharedToolExecutor>),
}

impl<T: ToolExecutor + 'static> From<Box<T>> for RegisteredToolExecutor {
    /// Records a synchronous executor without changing its invocation contract.
    fn from(executor: Box<T>) -> Self {
        Self::Synchronous(executor)
    }
}

impl From<Box<dyn ToolExecutor>> for RegisteredToolExecutor {
    /// Records an already erased synchronous executor at registration.
    fn from(executor: Box<dyn ToolExecutor>) -> Self {
        Self::Synchronous(executor)
    }
}

impl RegisteredToolExecutor {
    /// Prepares every registered contract once; only legacy adapters convert structured arguments to text.
    pub fn prepare<'a>(&'a self, request: &'a ToolCall, context: &'a ToolInvocationContext, checkAccess: bool)
        -> Result<PreparedToolInvocation<'a>, String> {
        match self {
            Self::Alias => Err("Invocation aliases must be resolved before acquiring an executor".into()),
            Self::Shared(executor) => executor.prepare(request, context, checkAccess),
            Self::Synchronous(executor) => {
                let tool = request.toLegacyTool();
                let validation = executor.validateParameters(&tool);
                if !validation.valid { return Err(validation.errorMessage); }
                let access = if checkAccess { Some(executor.accessSpec(&tool)?) } else { None };
                Ok(PreparedToolInvocation { access, invoke: Box::pin(async move { executor.invokeAndStream(&tool) }) })
            },
            Self::Asynchronous(executor) => {
                let tool = request.toLegacyTool();
                let validation = executor.validateParameters(&tool);
                if !validation.valid { return Err(validation.errorMessage); }
                let access = if checkAccess { Some(executor.accessSpec(&tool)?) } else { None };
                Ok(PreparedToolInvocation { access, invoke: Box::pin(async move { executor.invokeAndStreamAsync(&tool, context).await }) })
            },
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ToolEffect {
    READ,
    WRITE,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ToolBoundary {
    None,
    FilePath {
        effect: ToolEffect,
    },
    FilePair {
        source: ToolEffect,
        destination: ToolEffect,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolAccessSpec {
    pub effect: ToolEffect,
    pub boundary: ToolBoundary,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolValidationResult {
    pub valid: bool,
    pub errorMessage: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Keeps same-name invocation results ordered and shares their finalized markup with history.
    #[test]
    fn finalized_batch_retains_all_same_name_results_and_route_intent() {
        let batch = ToolExecutionBatch::new(
            ["a".repeat(100_000), "second result".to_string()].into_iter().map(|value| ToolResult {
                toolName: "grep_code".to_string(), success: true,
                result: stringResultData(value), error: None,
            }).collect(),
            Some(RouteChangeIntent { targetNodeId: "next-node".to_string() }),
        );
        let blocks = ChatMarkupRegex::tool_result_blocks(&batch.message);
        assert_eq!(blocks.len(), batch.results.len());
        assert_eq!(batch.results.len(), 2);
        assert!(blocks[0].body.starts_with("<content>aaa"));
        assert_eq!(blocks[1].body, "<content>second result</content>");
        assert_eq!(batch.routeChangeIntent.as_ref().unwrap().targetNodeId, "next-node");
        assert_eq!(blocks.iter().map(|block| block.raw.as_str()).collect::<Vec<_>>().join("\n"), batch.message);
    }


    /// Creates an explicit opaque turn snapshot for task-local tests without a package-manager fixture.
    fn turn_snapshot(owner: &str) -> ToolRuntimeContext {
        ToolRuntimeContext {
            callerChatId: Some(format!("chat:{owner}")),
            callerParticipantId: Some(format!("participant:{owner}")),
            workspacePath: None,
            workspaceFolders: Vec::new(),
            toolExposureMode: ToolExposureMode::FULL,
            extensionOwner: owner.to_string(),
            executionData: serde_json::json!({"turn": owner}).as_object().unwrap().clone(),
        }
    }

    /// Verifies concurrent awaited scopes retain different snapshots and leave no context in their parent task.
    #[tokio::test]
    async fn concurrent_execution_snapshots_remain_task_local() {
        let left = turn_snapshot("package.left");
        let right = turn_snapshot("package.right");
        let (first, second) = tokio::join!(
            ToolExecutionManager::scopeToolRuntimeContext(left.clone(), async {
                tokio::task::yield_now().await;
                ToolExecutionManager::currentToolRuntimeContext().unwrap()
            }),
            ToolExecutionManager::scopeToolRuntimeContext(right.clone(), async {
                tokio::task::yield_now().await;
                ToolExecutionManager::currentToolRuntimeContext().unwrap()
            }),
        );
        assert_eq!(first, left);
        assert_eq!(second, right);
        assert!(ToolExecutionManager::currentToolRuntimeContext().is_none());
    }

    /// Verifies nested invocations restore their parent snapshot after success and after original policy failure.
    #[tokio::test]
    async fn nested_execution_snapshots_restore_the_parent_on_failure() {
        let parent = turn_snapshot("package.parent");
        let child = turn_snapshot("package.child");
        ToolExecutionManager::scopeToolRuntimeContext(parent.clone(), async {
            let result: Result<(), String> = ToolExecutionManager::scopeToolRuntimeContext(child.clone(), async {
                assert_eq!(ToolExecutionManager::currentToolRuntimeContext(), Some(child));
                tokio::task::yield_now().await;
                Err(" exact rejected policy ".to_string())
            }).await;
            assert_eq!(result, Err(" exact rejected policy ".to_string()));
            assert_eq!(ToolExecutionManager::currentToolRuntimeContext(), Some(parent));
        }).await;
        assert!(ToolExecutionManager::currentToolRuntimeContext().is_none());
    }

    /// Rejects noncanonical owner identities and malformed optional participant identifiers without normalization.
    #[test]
    fn execution_snapshot_requires_exact_authenticated_identity() {
        let valid = turn_snapshot("package.owner");
        assert!(valid.validateExecutionContext().is_ok());
        for owner in ["", " ", " package.owner", "package.owner "] {
            let mut invalid = valid.clone();
            invalid.extensionOwner = owner.to_string();
            assert!(invalid.validateExecutionContext().is_err());
        }
        let mut invalid = valid;
        invalid.callerParticipantId = Some(" participant ".to_string());
        assert!(invalid.validateExecutionContext().is_err());
    }

    #[test]
    fn route_change_intent_uses_switch_core_result_text() {
        let tool = AITool {
            name: " switch_core ".to_string(),
            parameters: Vec::new(),
        };
        let result = ToolResult {
            toolName: "switch_core".to_string(),
            success: true,
            result: stringResultData(" core-target-1 \n"),
            error: None,
        };

        let intent = ToolExecutionManager::routeChangeIntentForResult(&tool, &result)
            .expect("switch_core success must produce route intent");

        assert_eq!(intent.targetNodeId, "core-target-1");
    }

    #[test]
    fn route_change_intent_recognizes_executed_cli_proxy_target() {
        let tool = AITool {
            name: "proxy".to_string(),
            parameters: vec![ToolParameter {
                name: "tool_name".to_string(),
                value: "switch_core".to_string(),
            }],
        };
        let result = ToolResult {
            toolName: "switch_core".to_string(),
            success: true,
            result: stringResultData("core-target-2"),
            error: None,
        };
        assert_eq!(
            ToolExecutionManager::routeChangeIntentForResult(&tool, &result)
                .expect("executed switch_core via CLI proxy must produce route intent")
                .targetNodeId,
            "core-target-2",
        );

        let mut failed = result.clone();
        failed.success = false;
        assert!(ToolExecutionManager::routeChangeIntentForResult(&tool, &failed).is_none());
        let mut mismatched = result;
        mismatched.toolName = "other_tool".to_string();
        assert!(ToolExecutionManager::routeChangeIntentForResult(&tool, &mismatched).is_none());
    }
}

#[cfg(test)]
mod proxyEnvelopeTests {
    use super::*;

    fn call(name: &str, json: serde_json::Value) -> ToolCall {
        let parameters = json
            .as_object()
            .expect("test envelope must be an object")
            .clone()
            .into_iter()
            .collect::<BTreeMap<_, _>>();
        ToolCall { name: name.to_string(), parameters }
    }

    fn resolve(name: &str, json: serde_json::Value) -> Result<ToolCall, String> {
        call(name, json).resolveProxyEnvelope()
    }

    /// A well-formed envelope must pass through untouched.
    #[test]
    fn direct_target_passes_through() {
        let resolved = resolve("package_proxy", serde_json::json!({
            "tool_name": "extended_chat:list_chats",
            "params": { "limit": 1 }
        }))
        .expect("direct target resolves");
        assert_eq!(resolved.name, "extended_chat:list_chats");
        assert_eq!(resolved.parameters.get("limit").and_then(|v| v.as_u64()), Some(1));
        assert!(!resolved.parameters.contains_key("tool_name"));
    }

    /// The reported bug: the proxy names itself and nests the real call one level down.
    #[test]
    fn self_target_unwraps_one_level() {
        let resolved = resolve("package_proxy", serde_json::json!({
            "tool_name": "package_proxy",
            "params": { "tool_name": "extended_chat:list_chats" }
        }))
        .expect("nested envelope resolves");
        assert_eq!(resolved.name, "extended_chat:list_chats");
    }

    /// Nested envelope that also carries real arguments must keep them.
    #[test]
    fn self_target_keeps_inner_arguments() {
        let resolved = resolve("package_proxy", serde_json::json!({
            "tool_name": "package_proxy",
            "params": { "tool_name": "extended_chat:list_chats", "params": { "limit": 2 } }
        }))
        .expect("nested envelope resolves");
        assert_eq!(resolved.name, "extended_chat:list_chats");
        assert_eq!(resolved.parameters.get("limit").and_then(|v| v.as_u64()), Some(2));
    }

    /// Two self-targeting levels still resolve.
    #[test]
    fn self_target_unwraps_two_levels() {
        let resolved = resolve("package_proxy", serde_json::json!({
            "tool_name": "package_proxy",
            "params": { "tool_name": "package_proxy", "params": { "tool_name": "extended_chat:list_chats" } }
        }))
        .expect("double nested envelope resolves");
        assert_eq!(resolved.name, "extended_chat:list_chats");
    }

    /// Legacy text encoding of `params` is accepted.
    #[test]
    fn text_encoded_params_are_parsed() {
        let resolved = resolve("package_proxy", serde_json::json!({
            "tool_name": "extended_chat:list_chats",
            "params": "{\"limit\":3}"
        }))
        .expect("text params resolve");
        assert_eq!(resolved.name, "extended_chat:list_chats");
        assert_eq!(resolved.parameters.get("limit").and_then(|v| v.as_u64()), Some(3));
    }

    /// A provider wrapper that hides `tool_name` is still understood.
    #[test]
    fn provider_wrapper_target_is_found() {
        let resolved = resolve("package_proxy", serde_json::json!({
            "arguments": { "tool_name": "extended_chat:list_chats" }
        }))
        .expect("wrapper target resolves");
        assert_eq!(resolved.name, "extended_chat:list_chats");
    }

    /// No target at all must fail with guidance, never panic or recurse forever.
    #[test]
    fn missing_target_reports_guidance() {
        let error = resolve("package_proxy", serde_json::json!({ "params": {} }))
            .expect_err("missing target must fail");
        assert!(error.contains("package_proxy"), "guidance mentions the call shape: {error}");
        assert!(
            error.contains("Received arguments") || error.contains("keys received"),
            "error echoes what arrived: {error}"
        );
    }

    /// `params` nested one level too deep still yields the real target.
    #[test]
    fn target_nested_inside_params_is_found() {
        let resolved = resolve("package_proxy", serde_json::json!({
            "params": { "params": { "tool_name": "extended_chat:list_chats" } }
        }))
        .expect("deeply nested target resolves");
        assert_eq!(resolved.name, "extended_chat:list_chats");
    }

    /// Text-encoded `params` that itself holds the nested envelope.
    #[test]
    fn self_target_with_text_encoded_params_resolves() {
        let resolved = resolve("package_proxy", serde_json::json!({
            "tool_name": "package_proxy",
            "params": "{\"tool_name\":\"extended_chat:list_chats\"}"
        }))
        .expect("text encoded nested envelope resolves");
        assert_eq!(resolved.name, "extended_chat:list_chats");
    }

    /// Real device capture: one logical call arrived wrapped three extra times by the transport.
    #[test]
    fn transport_rewrapped_envelope_reaches_real_target() {
        let resolved = resolve("package_proxy", serde_json::json!({
            "tool_name": "package_proxy",
            "params": {
                "tool_name": "package_proxy",
                "params": {
                    "tool_name": "package_proxy",
                    "params": { "tool_name": "extended_chat:list_chats" }
                }
            }
        }))
        .expect("transport re-wrapped envelope resolves");
        assert_eq!(resolved.name, "extended_chat:list_chats");
    }

    /// Two arguments split across envelope layers must both survive.
    #[test]
    fn arguments_from_every_layer_are_merged() {
        let resolved = resolve("package_proxy", serde_json::json!({
            "tool_name": "package_proxy",
            "limit": 5,
            "params": {
                "tool_name": "package_proxy",
                "params": { "tool_name": "extended_chat:list_chats", "order": "asc" }
            }
        }))
        .expect("merged arguments resolve");
        assert_eq!(resolved.name, "extended_chat:list_chats");
        assert_eq!(resolved.parameters.get("limit").and_then(|v| v.as_u64()), Some(5));
        assert_eq!(resolved.parameters.get("order").and_then(|v| v.as_str()), Some("asc"));
    }

    /// Only the proxy naming itself, with no inner target, must fail with guidance.
    #[test]
    fn proxy_chain_without_real_target_reports_guidance() {
        let error = resolve("package_proxy", serde_json::json!({
            "tool_name": "package_proxy",
            "params": { "tool_name": "package_proxy", "params": {} }
        }))
        .expect_err("chain without target must fail");
        assert!(error.contains("Received arguments"), "echoes what arrived: {error}");
    }

    /// Catalog entries stay rejected: they are not callable tools.
    #[test]
    fn catalog_entry_is_rejected() {
        let error = resolve("package_proxy", serde_json::json!({ "tool_name": "search" }))
            .expect_err("catalog entry must fail");
        assert!(error.contains("catalog entry"), "explains why: {error}");
    }
}
