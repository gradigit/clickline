# Evaluations for clickline-custom

## Scenario 1: Happy path — add a service link to a new repo

**Given** a git repo with no `.clickline` file and clickline installed
**When** user says "Add a Railway link to my statusline"
**Then**
- [ ] Skill activates
- [ ] Detects no existing `.clickline`, does not error
- [ ] Asks for Railway app name and constructs URL `https://<app>.up.railway.app`
- [ ] Asks where to save (repo vs global)
- [ ] Writes `.clickline` with valid JSON containing the item
- [ ] Appends `custom_<name>` to LAYOUT in `clickline.conf`
- [ ] Shows confirmation with preview of how it will look

## Scenario 2: Update existing — add item when `.clickline` already has entries

**Given** a repo with an existing `.clickline` containing a Railway item
**When** user says "Add a Supabase dashboard link to the statusline"
**Then**
- [ ] Skill activates and shows current items from `.clickline`
- [ ] Collects Supabase project ref, constructs URL
- [ ] Writes updated `.clickline` preserving the original Railway item
- [ ] Appends `custom_supabase` to LAYOUT without duplicating existing entries

## Scenario 3: Global item — system indicator to global config

**Given** clickline installed, user wants an item across all repos
**When** user says "Add a kubernetes context indicator to my statusline globally"
**Then**
- [ ] Skill activates
- [ ] Routes to global file (`~/.claude/clickline-custom.json`) based on "globally"
- [ ] Collects cmd (`kubectl config current-context`), suggests condition (`command -v kubectl`)
- [ ] Writes to `clickline-custom.json` with cmd and condition fields
- [ ] Appends `custom_kube-ctx` to LAYOUT

## Scenario 4: Should NOT trigger

**Given** user asks about clickline but not about adding custom items
**When** user says any of:
- "Install clickline"
- "Configure my statusline layout"
- "How do I change the statusline colors?"
- "Remove an item from the statusline"
**Then**
- [ ] Skill does NOT activate
- [ ] User is directed to `install.sh` or the TUI configurator instead
