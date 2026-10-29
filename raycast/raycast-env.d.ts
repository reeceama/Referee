/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `open-search` command */
  export type OpenSearch = ExtensionPreferences & {}
  /** Preferences accessible in the `open-capture` command */
  export type OpenCapture = ExtensionPreferences & {}
  /** Preferences accessible in the `research-mode` command */
  export type ResearchMode = ExtensionPreferences & {}
  /** Preferences accessible in the `check-selection` command */
  export type CheckSelection = ExtensionPreferences & {}
  /** Preferences accessible in the `new-note` command */
  export type NewNote = ExtensionPreferences & {}
  /** Preferences accessible in the `save-link` command */
  export type SaveLink = ExtensionPreferences & {}
  /** Preferences accessible in the `log-ai-use` command */
  export type LogAiUse = ExtensionPreferences & {}
  /** Preferences accessible in the `switch-project` command */
  export type SwitchProject = ExtensionPreferences & {}
  /** Preferences accessible in the `library` command */
  export type Library = ExtensionPreferences & {}
  /** Preferences accessible in the `evidence` command */
  export type Evidence = ExtensionPreferences & {}
  /** Preferences accessible in the `notes` command */
  export type Notes = ExtensionPreferences & {}
  /** Preferences accessible in the `meetings` command */
  export type Meetings = ExtensionPreferences & {}
  /** Preferences accessible in the `ai-use` command */
  export type AiUse = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `open-search` command */
  export type OpenSearch = {
  /** Search */
  "q": string
}
  /** Arguments passed to the `open-capture` command */
  export type OpenCapture = {}
  /** Arguments passed to the `research-mode` command */
  export type ResearchMode = {}
  /** Arguments passed to the `check-selection` command */
  export type CheckSelection = {}
  /** Arguments passed to the `new-note` command */
  export type NewNote = {}
  /** Arguments passed to the `save-link` command */
  export type SaveLink = {
  /** Link */
  "url": string
}
  /** Arguments passed to the `log-ai-use` command */
  export type LogAiUse = {}
  /** Arguments passed to the `switch-project` command */
  export type SwitchProject = {}
  /** Arguments passed to the `library` command */
  export type Library = {}
  /** Arguments passed to the `evidence` command */
  export type Evidence = {}
  /** Arguments passed to the `notes` command */
  export type Notes = {}
  /** Arguments passed to the `meetings` command */
  export type Meetings = {}
  /** Arguments passed to the `ai-use` command */
  export type AiUse = {}
}

