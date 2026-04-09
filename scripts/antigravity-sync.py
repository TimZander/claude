#!/usr/bin/env python3
import os
import json
import glob

def sync_plugins_to_antigravity():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    plugins_dir = os.path.join(repo_root, "plugins")
    agents_skills_dir = os.path.join(repo_root, ".agents", "skills")

    os.makedirs(agents_skills_dir, exist_ok=True)
    compiled_count = 0

    for plugin_file in glob.glob(os.path.join(plugins_dir, "*", ".claude-plugin", "plugin.json")):
        try:
            with open(plugin_file, "r") as f:
                data = json.load(f)
            
            name = data.get("name")
            description = data.get("description", "")
            
            if not name:
                continue
                
            md_path = None
            
            # Check explicit resolve path first
            if data.get("commands") and data["commands"][0].get("resolve"):
                md_path = os.path.normpath(os.path.join(os.path.dirname(plugin_file), data["commands"][0]["resolve"]))
            else:
                # Fallback to scanning the commands directory
                plugin_root_dir = os.path.dirname(os.path.dirname(plugin_file))
                md_candidates = glob.glob(os.path.join(plugin_root_dir, "commands", "*.md"))
                if md_candidates:
                    md_path = md_candidates[0]
            
            if not md_path or not os.path.isfile(md_path):
                print(f"Warning: Prompt markdown not found for {name}")
                continue
                
            with open(md_path, "r") as f:
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
                    
            with open(skill_file_path, "w") as f:
                f.write("---\n")
                f.write(f"name: {name}\n")
                f.write(f'description: "{description}"\n')
                f.write("---\n\n")
                f.write(content_body)

            # Symlink any local scripts so bash commands inside the prompts continue to work relatively
            original_scripts_dir = os.path.join(os.path.dirname(os.path.dirname(plugin_file)), "scripts")
            target_scripts_dir = os.path.join(skill_dir, "scripts")
            if os.path.isdir(original_scripts_dir):
                if not os.path.exists(target_scripts_dir):
                    os.symlink(original_scripts_dir, target_scripts_dir)
                    
            compiled_count += 1
            print(f"Compiled: {name}")

        except Exception as e:
            print(f"Error compiling {plugin_file}: {e}")

    print(f"\nSuccess! Compiled {compiled_count} Claude plugins natively into {agents_skills_dir} for Antigravity.")

if __name__ == "__main__":
    sync_plugins_to_antigravity()
