#![allow(non_snake_case)]

use uuid::Uuid;

use operit_store::RuntimeStorageHost::defaultRuntimeStorageHost;
use operit_store::RuntimeStorePaths::RuntimeStorePaths;
use operit_util::RuntimeStorageLayout::RUNTIME_TTS_AUDIO_DIR_PATH;

use crate::data::preferences::TtsConfigManager::TtsConfigManager;
use crate::services::LocalProviderService::LocalProviderService;
use operit_host_api::HostManager::HostManager;
use operit_local_models::LocalInference::LocalModelSelection;
use operit_model::TtsConfig::{TtsConfig, TtsProviderType, TtsSynthesisResult};
use operit_providers::tts::VoiceService::VoiceService;
use operit_providers::tts::VoiceServiceFactory::VoiceServiceFactory;
use operit_util::TtsCleaner::TtsCleaner;
use operit_util::TtsSegmenter::TtsSegmenter;

#[derive(Clone)]
/// Synthesizes speech audio using exact resolved TTS configurations.
pub struct TtsSynthesisService {
    paths: RuntimeStorePaths,
    ttsConfigManager: TtsConfigManager,
    context: Option<HostManager>,
}

/// Adapts the runtime local model provider to the shared TTS voice contract.
struct LocalModelVoiceProvider {
    service: LocalProviderService,
    model: LocalModelSelection,
}

impl LocalModelVoiceProvider {
    /// Creates a voice provider for one exact installed local model binding.
    fn new(config: &TtsConfig, context: &HostManager) -> Result<Self, String> {
        let service = LocalProviderService::getInstance(context)?;
        let model = LocalProviderService::parseModelBinding(config.model.clone())?;
        Ok(Self { service, model })
    }
}

impl VoiceService for LocalModelVoiceProvider {
    /// Synthesizes one text segment through the installed local TTS engine.
    fn synthesize(&self, config: &TtsConfig, text: &str) -> Result<Vec<u8>, String> {
        let response = self.service.synthesizeAudio(
            self.model.clone(),
            text.to_string(),
            config.voice.clone(),
            config.speed,
        )?;
        if response.outputFormat != "wav" {
            return Err(format!(
                "LOCAL_MODEL TTS returned unsupported format: {}",
                response.outputFormat
            ));
        }
        Ok(response.audioBytes)
    }
}

impl TtsSynthesisService {
    /// Creates a synthesis service from application host context.
    pub fn getInstance(context: &HostManager) -> Self {
        let paths = RuntimeStorePaths::default();
        Self::newWithContext(paths, context.clone())
    }

    /// Creates a synthesis service for explicit runtime paths.
    pub fn new(paths: RuntimeStorePaths) -> Self {
        Self {
            ttsConfigManager: TtsConfigManager::new(paths.clone()),
            paths,
            context: None,
        }
    }

    /// Creates a synthesis service with runtime paths and host context.
    pub fn newWithContext(paths: RuntimeStorePaths, context: HostManager) -> Self {
        Self {
            ttsConfigManager: TtsConfigManager::new(paths.clone()),
            paths,
            context: Some(context),
        }
    }

    /// Synthesizes text with the exact configuration selected by a resolved chat profile.
    pub fn synthesizeWithConfig(
        &self,
        ttsConfigId: &str,
        text: &str,
    ) -> Result<TtsSynthesisResult, String> {
        let ttsConfigId = ttsConfigId.trim();
        if ttsConfigId.is_empty() {
            return Err("tts config id is empty".to_string());
        }
        let cleanedText = TtsCleaner::clean(text);
        if cleanedText.is_empty() {
            return Err("tts text is empty".to_string());
        }
        let config = self
            .ttsConfigManager
            .getTtsConfig(ttsConfigId)
            .map_err(|error| error.to_string())?;
        self.synthesizeWithResolvedConfig(ttsConfigId, &config, &cleanedText)
    }

    /// Returns provider audio directly for host plugins and remote device playback.
    pub fn synthesizeAudioWithConfig(&self, id: &str, text: &str)
        -> Result<operit_plugin_sdk::js_sdk::results::TtsSynthesizeResultData, String> {
        if id.trim().is_empty() { return Err("tts config id is empty".into()); }
        let text = TtsCleaner::clean(text);
        if text.is_empty() { return Err("tts text is empty".into()); }
        let config = self.ttsConfigManager.getTtsConfig(id).map_err(|e| e.to_string())?;
        let provider = self.createVoiceService(&config)?;
        let extension = provider.outputExtension(&config)?;
        let contentType = match extension {
            "wav" => "audio/wav", "mp3" => "audio/mpeg", "ogg" => "audio/ogg",
            "opus" => "audio/opus", "flac" => "audio/flac", "aac" => "audio/aac",
            "pcm" => "application/octet-stream",
            _ => return Err(format!("Unsupported TTS output format: {extension}")),
        };
        let mut segments = Vec::new();
        for segment in TtsSegmenter::segment(&text, Self::segmentCharsFor(&config)) {
            let audio = provider.synthesize(&config, &segment)?;
            if audio.is_empty() { return Err("TTS provider returned empty audio".into()); }
            segments.push(operit_plugin_sdk::js_sdk::results::TtsAudioSegment { audio, contentType: contentType.into() });
        }
        Ok(operit_plugin_sdk::js_sdk::results::TtsSynthesizeResultData { segments })
    }

    /// Synthesizes cleaned text and writes every generated segment to runtime storage.
    fn synthesizeWithResolvedConfig(
        &self,
        audioNamePrefix: &str,
        config: &TtsConfig,
        cleanedText: &str,
    ) -> Result<TtsSynthesisResult, String> {
        let voiceService = self.createVoiceService(config)?;
        let segments = TtsSegmenter::segment(cleanedText, Self::segmentCharsFor(config));
        let storageHost = defaultRuntimeStorageHost();
        let mut audioPaths = Vec::new();
        let mut audioStoragePaths = Vec::new();
        // 本地神经 TTS 必须按短句合成才不会漏读，但播放侧只播第一条音频，
        // 所以碎段必须在写盘前合并回一个 WAV，否则用户只听到头一句。
        let mut generated: Vec<Vec<u8>> = Vec::new();
        for segment in segments.iter() {
            generated.push(voiceService.synthesize(config, segment)?);
        }
        let parts = if generated.len() > 1
            && TtsProviderType::normalize(&config.providerType) == TtsProviderType::LOCAL_MODEL
        {
            vec![mergeWavParts(&generated)?]
        } else {
            generated
        };
        for (index, bytes) in parts.into_iter().enumerate() {
            let extension = voiceService.outputExtension(config)?;
            let fileName = format!(
                "{}_{}_{}.{}",
                audioNamePrefix,
                Uuid::new_v4(),
                index,
                extension
            );
            let storagePath = format!("{RUNTIME_TTS_AUDIO_DIR_PATH}/{fileName}");
            storageHost
                .writeBytes(&storagePath, &bytes)
                .map_err(|error| error.message)?;
            let path = self.paths.runtime_storage_path(&storagePath);
            audioPaths.push(path.to_string_lossy().to_string());
            audioStoragePaths.push(storagePath);
        }
        Ok(TtsSynthesisResult {
            audioPaths,
            audioStoragePaths,
        })
    }

    /// Returns the synthesis segment size appropriate for one provider.
    ///
    /// 本地神经 TTS 的生成速度低于实时，若等整篇 4000 字合成完再播放，
    /// 用户会长时间停在「生成中」。切到短段后第一段很快可播，
    /// 后续段由播放队列无缝接续；Android 端模型已常驻，重段不会再重新加载权重。
    fn segmentCharsFor(config: &TtsConfig) -> usize {
        if TtsProviderType::normalize(&config.providerType) != TtsProviderType::LOCAL_MODEL {
            return 4000;
        }
        // 零样本克隆（ZipVoice）单次生成的长度被参考音频时长(~6.8s)卡住：
        // 实测每调用一次只产出约 5.7s 音频，60 字输入也只念出前 20 来字。
        // 因此按 18 字切碎，让每次生成都落在这个上限内，最后合并成一个 WAV。
        if config.model.to_ascii_lowercase().contains("zipvoice") {
            18
        } else {
            280
        }
    }

    /// Creates the provider adapter selected by one normalized TTS configuration.
    fn createVoiceService(&self, config: &TtsConfig) -> Result<Box<dyn VoiceService>, String> {
        let providerType = TtsProviderType::normalize(&config.providerType);
        match providerType.as_str() {
            TtsProviderType::LOCAL_MODEL => {
                let context = self.context.as_ref().ok_or_else(|| {
                    "HostManager is required for LOCAL_MODEL TTS synthesis".to_string()
                })?;
                Ok(Box::new(LocalModelVoiceProvider::new(config, context)?))
            }
            _ => VoiceServiceFactory::createVoiceService(config, self.context.as_ref()),
        }
    }
}

/// Merges same-format 16-bit PCM WAV parts into one WAV payload.
///
/// ZipVoice 之类的零样本克隆模型在长输入下会少生成，必须按句切碎合成；
/// 但播放链路一次只消费一条音频，因此把碎段按顺序拼成一个文件最稳。
fn mergeWavParts(parts: &[Vec<u8>]) -> Result<Vec<u8>, String> {
    let mut formatChunk: Option<Vec<u8>> = None;
    let mut pcm = Vec::new();
    for part in parts {
        let (format, data) = splitWavPart(part)?;
        match formatChunk.as_deref() {
            Some(existing) if existing != format.as_slice() => {
                return Err("tts wav segments have mismatched formats".to_string());
            }
            _ => formatChunk = Some(format),
        }
        pcm.extend_from_slice(data);
    }
    let format = formatChunk.ok_or_else(|| "tts wav segments are empty".to_string())?;
    let dataSize = pcm.len() as u32;
    let riffSize = 4u32
        .checked_add(8 + format.len() as u32)
        .and_then(|value| value.checked_add(8 + dataSize))
        .ok_or_else(|| "tts wav merged payload is too large".to_string())?;
    let mut output = Vec::with_capacity(riffSize as usize + 8);
    output.extend_from_slice(b"RIFF");
    output.extend_from_slice(&riffSize.to_le_bytes());
    output.extend_from_slice(b"WAVE");
    output.extend_from_slice(b"fmt ");
    output.extend_from_slice(&(format.len() as u32).to_le_bytes());
    output.extend_from_slice(&format);
    output.extend_from_slice(b"data");
    output.extend_from_slice(&dataSize.to_le_bytes());
    output.extend_from_slice(&pcm);
    Ok(output)
}

/// Returns one WAV part's format chunk payload and PCM data.
fn splitWavPart(part: &[u8]) -> Result<(Vec<u8>, &[u8]), String> {
    if part.len() < 12 || &part[0..4] != b"RIFF" || &part[8..12] != b"WAVE" {
        return Err("tts wav segment is not a RIFF/WAVE payload".to_string());
    }
    let mut cursor = 12usize;
    let mut format = None;
    let mut data = None;
    while cursor + 8 <= part.len() {
        let id = &part[cursor..cursor + 4];
        let size = u32::from_le_bytes(
            part[cursor + 4..cursor + 8]
                .try_into()
                .map_err(|_| "tts wav segment has a truncated chunk header".to_string())?,
        ) as usize;
        let body = cursor + 8;
        let end = body
            .checked_add(size)
            .ok_or_else(|| "tts wav segment chunk size overflows".to_string())?;
        if end > part.len() {
            return Err("tts wav segment chunk exceeds payload".to_string());
        }
        if id == b"fmt " {
            format = Some(part[body..end].to_vec());
        } else if id == b"data" {
            data = Some(&part[body..end]);
        }
        cursor = end + (size & 1);
    }
    let format = format.ok_or_else(|| "tts wav segment has no fmt chunk".to_string())?;
    let data = data.ok_or_else(|| "tts wav segment has no data chunk".to_string())?;
    Ok((format, data))
}
