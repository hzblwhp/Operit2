import { readCharacter } from "./drafts";
import type { CharacterRepository } from "./canonical";
import type { Card, ConversationGroupRecord, Group, MemorySpace, Tag } from "./model";
import { assertConversationGroups, assertGroup, assertInteger, assertObject, assertString, assertTag } from "./validation";
import { assertMemorySpace } from "./storage/state";

/// 带可读错误的 JSON 解析：空文件或非 JSON 时给出明确提示，
/// 而不是把引擎的 "Unexpected end of JSON input" 直接抛给用户。
function parseBackupDocument(kind: string, content: string): unknown {
  const text = content.trim();
  if (text.length === 0) {
    throw new Error(kind + "内容为空，请选择导出的备份文件（.json）");
  }
  try {
    return JSON.parse(text);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(kind + "不是合法的 JSON：" + detail);
  }
}


/** Requires complete character and tag backups without manufacturing absent arrays. */
export function decodeCharacterBackup(content: string): { version: 2; characterCards: Card[]; promptTags: Tag[]; conversationGroups: ConversationGroupRecord[] } {
  assertString(content, "character backup"); const document: unknown = parseBackupDocument("角色卡备份", content); assertObject(document, "character backup");
  if (document.version !== 2) throw new Error("Unsupported plugin character backup version");
  assertConversationGroups(document.conversationGroups);
  if (!Array.isArray(document.characterCards) || !Array.isArray(document.promptTags)) throw new Error("Character backup requires complete characterCards and promptTags arrays");
  const characterCards = document.characterCards.map(card => readCharacter(card));
  for (const tag of document.promptTags) assertTag(tag);
  return { version: 2, characterCards, promptTags: document.promptTags, conversationGroups: document.conversationGroups };
}
/** Requires complete group backups rather than defaulting missing groups to an empty library. */
export function decodeGroupBackup(content: string): { characterGroups: Group[] } {
  assertString(content, "group backup"); const document: unknown = parseBackupDocument("群组备份", content); assertObject(document, "group backup");
  if (!Array.isArray(document.characterGroups)) throw new Error("Group backup requires complete characterGroups records");
  for (const group of document.characterGroups) assertGroup(group);
  return { characterGroups: document.characterGroups };
}
/** Exports all full character and tag records from the same operation snapshot. */
export async function exportCharacterBackup(repository: CharacterRepository): Promise<string> {
  const characterCards = await repository.listCharacters(), promptTags = await repository.listTags(), conversationGroups = await repository.readConversationGroupsForBackup();
  assertConversationGroups(conversationGroups);
  return JSON.stringify({ version: 2, characterCards, promptTags, conversationGroups }, null, 2);
}
/** Exports full group records from the same operation snapshot. */
export async function exportGroupBackup(repository: CharacterRepository): Promise<string> {
  return JSON.stringify({ characterGroups: await repository.listGroups() }, null, 2);
}
/** Preserves document nodes, chunks, relationships, settings, candidate metadata and USER content. */
export interface MemoryBackup { version: "2.0"; exportDate: number; space: MemorySpace; userMarkdown: string }
/** Parses the plugin's explicit full-record backup format; legacy migration is not performed. */
export function decodeMemoryBackup(content: string): MemoryBackup {
  assertString(content, "memory backup"); const document: unknown = parseBackupDocument("记忆备份", content); assertObject(document, "memory backup");
  if (document.version !== "2.0") throw new Error("Unsupported memory backup version; this plugin uses full-record version 2.0");
  assertInteger(document.exportDate, "exportDate", 0); assertMemorySpace(document.space); assertString(document.userMarkdown, "USER.md backup content");
  return { version: "2.0", exportDate: document.exportDate, space: document.space, userMarkdown: document.userMarkdown };
}
/** Exports the entire memory space, never a graph or portable non-document projection. */
export async function exportMemoryBackup(ownerKey: string, repository: CharacterRepository): Promise<string> {
  const backup: MemoryBackup = { version: "2.0", exportDate: Date.now(), space: await repository.readMemorySpace(ownerKey), userMarkdown: (await repository.readUser(ownerKey)).content };
  return JSON.stringify(backup, null, 2);
}
