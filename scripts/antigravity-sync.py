#!/usr/bin/env python3
import os
import json
import glob
import shutil


def _yaml_quote(value: str) -> str:
    """Quote a string for safe YAML scalar output (no PyYAML dependency)."""
    if not value:
        return '""'
    # If value contains characters that could break YAML, wrap in double quotes
    # and escape internal double-quotes / backslashes.
    needs_quoting = any(ch in value for ch in (':', '#', '"', "'", '{', '}', '[', ']', ',', '&', '*', '!', '|', '>', '%', '@', '`'))
    if needs_quoting:
        escaped = value.replace('\\', '\\\\').replace('"', '\\"')
        return f'"{escaped}"'
    return value


def sync_plugins_to_antigravity():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    plugins_dir = os.path.join(repo_root, "plugins")
    agents_skills_dir = os.path.join(
        os.path.expanduser("~"), ".gemini", "antigravity", "skills"
    )

    # Wipe stale output so renamed/deleted plugins don't linger
    if os.path.isdir(agents_skills_dir):
        shutil.rmtree(agents_skills_dir)
    os.makedirs(agents_skills_dir, exist_ok=True)

    compiled_count = 0

    # Discover plugin directories that have no .claude-plugin/plugin.json
    all_plugin_dirs = {
        os.path.basename(d)
        for d in glob.glob(os.path.join(plugins_dir, "*"))
        if os.path.isdir(d)
    }
    found_plugin_dirs = set()

    for plugin_file in glob.glob(os.path.join(plugins_dir, "*", ".claude-plugin", "plugin.json")):
        plugin_root_dir = os.path.dirname(os.path.dirname(plugin_file))
        found_plugin_dirs.add(os.path.basename(plugin_root_dir))

        try:
            with open(plugin_file, "r", encoding="utf-8") as f:
                data = json.load(f)

            name = data.get("name")
            description = data.get("description", "")

            if not name:
                continue

            md_path = None

            # Check explicit resolve path first (only the first command is used —
            # multi-command plugins are not yet supported by Antigravity skills)
            if data.get("commands") and data["commands"][0].get("resolve"):
                md_path = os.path.normpath(os.path.join(os.path.dirname(plugin_file), data["commands"][0]["resolve"]))
            else:
                # Fallback to scanning the commands directory
                md_candidates = glob.glob(os.path.join(plugin_root_dir, "commands", "*.md"))
                if md_candidates:
                    md_path = md_candidates[0]

            if not md_path or not os.path.isfile(md_path):
                print(f"Warning: Prompt markdown not found for {name}")
                continue

            with open(md_path, "r", encoding="utf-8") as f:
                md_content = f.read()

            skill_dir = os.path.join(agents_skills_dir, name)
            os.makedirs(skill_dir, exist_ok=True)

            skill_file_path = os.path.join(skill_dir, "SKILL.md")

            content_body = md_content
            # Strip out Claude-specific frontmatter to avoid duplicate YAML issues
            if md_content.startswith("---"):
                parts = md_content.split("---", 2)
                if len(parts) >= 3:
                    content_body = parts[2].strip()

            # Use _yaml_quote for safe YAML serialization (handles quotes, colons, etc.)
            with open(skill_file_path, "w", encoding="utf-8") as f:
                f.write("---\n")
                f.write(f"name: {_yaml_quote(name)}\n")
                f.write(f"description: {_yaml_quote(description)}\n")
                f.write("---\n\n")
                f.write(content_body)

            # Symlink any local scripts so bash commands inside the prompts continue to work
            original_scripts_dir = os.path.join(plugin_root_dir, "scripts")
            target_scripts_dir = os.path.join(skill_dir, "scripts")
            if os.path.isdir(original_scripts_dir):
                # Remove stale/broken symlinks or copies before recreating
                if os.path.islink(target_scripts_dir):
                    os.unlink(target_scripts_dir)
                elif os.path.isdir(target_scripts_dir):
                    shutil.rmtree(target_scripts_dir)
                # Prefer relative symlink; fall back to copy on Windows without Developer Mode
                rel_path = os.path.relpath(original_scripts_dir, skill_dir)
                try:
                    os.symlink(rel_path, target_scripts_dir, target_is_directory=True)
                except OSError:
                    shutil.copytree(original_scripts_dir, target_scripts_dir)

            compiled_count += 1
            print(f"  Compiled: {name}")

        except Exception as e:
            print(f"  Error compiling {plugin_file}: {e}")

    # Report plugin directories that were skipped (no plugin.json)
    skipped = sorted(all_plugin_dirs - found_plugin_dirs)
    if skipped:
        print(f"\nSkipped (no .claude-plugin/plugin.json): {', '.join(skipped)}")

    print(f"\nSuccess! Compiled {compiled_count} plugin(s) into {agents_skills_dir}")


if __name__ == "__main__":
    sync_plugins_to_antigravity()
