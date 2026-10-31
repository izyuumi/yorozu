// The bundle scripts/generate.ts writes from the repository. The server reads only this file at runtime.
import bundle from "./content.json" with { type: "json" };

export type Platform = "ios" | "macos";

export interface Section {
  heading: string;
  anchor: string;
  level: number;
  text: string;
}

export interface Doc {
  id: string;
  path: string;
  title: string;
  uri: string;
  text: string;
  sections: Section[];
}

export interface AppSetting {
  key: string;
  title: string;
  platforms: Platform[];
  location: string;
  description: string;
  type: "boolean" | "integer" | "enum";
  default: string | number | boolean;
  options?: string[];
  source: string[];
}

export interface HostSetting {
  key: string;
  type: string;
  default: string;
  description: string;
  set: string;
  source: string[];
}

export interface TroubleEntry {
  symptom: string;
  fix: string;
  source: string;
}

export interface Permission {
  key: string;
  kind: "usage" | "entitlement" | "runtime";
  meaning: string;
  prompt?: string;
  source: string;
}

export interface SetupStep {
  title: string;
  text: string;
  doc?: string;
  details?: string;
}

export interface SetupGuide {
  platform: Platform;
  title: string;
  steps: SetupStep[];
}

export interface Release {
  version: string;
  text: string;
}

export interface Content {
  docs: Doc[];
  settings: { app: AppSetting[]; host: HostSetting[] };
  troubleshooting: TroubleEntry[];
  permissions: Record<Platform, Permission[]>;
  guides: Record<Platform, SetupGuide>;
  releases: Release[];
}

export const content: Content = bundle as Content;
