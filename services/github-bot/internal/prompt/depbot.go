package prompt

import (
	"fmt"
	"strings"
)

// DepbotContext contains context for building a dependency review prompt.
type DepbotContext struct {
	Owner    string
	Repo     string
	PRNumber int
	PRTitle  string
	PRBody   string
	PRAuthor string
	HeadRef  string
	Diff     string
}

// BuildDepbotPrompt builds the prompt for automated dependency review.
func BuildDepbotPrompt(ctx DepbotContext) string {
	var b strings.Builder

	b.WriteString("You are reviewing a dependency update pull request.\n\n")

	fmt.Fprintf(&b, "## Repository\n%s/%s\n\n", ctx.Owner, ctx.Repo)

	fmt.Fprintf(&b, "## Pull Request #%d: %s\n", ctx.PRNumber, ctx.PRTitle)
	fmt.Fprintf(&b, "Author: %s (automated dependency updater)\n\n", ctx.PRAuthor)

	if ctx.PRBody != "" {
		b.WriteString("## PR Description\n")
		b.WriteString(ctx.PRBody)
		b.WriteString("\n\n")
	}

	if ctx.Diff != "" {
		b.WriteString("## Dependency Diff\n```diff\n")
		b.WriteString(ctx.Diff)
		b.WriteString("\n```\n\n")
	}

	b.WriteString("---\n\n")
	b.WriteString("## Your Task\n\n")
	fmt.Fprintf(&b, "The repository `%s/%s` is cloned in your workspace. The PR branch `%s` needs to be checked out first.\n", ctx.Owner, ctx.Repo, ctx.HeadRef)
	fmt.Fprintf(&b, "Run: `git fetch origin %s && git checkout %s`\n\n", ctx.HeadRef, ctx.HeadRef)

	b.WriteString("Perform the following analysis:\n\n")

	b.WriteString("### 1. Identify Dependencies Being Updated\n")
	b.WriteString("- List each dependency: name, old version -> new version\n")
	b.WriteString("- Note whether it's a major, minor, or patch version bump\n\n")

	b.WriteString("### 2. Analyze Each Update\n")
	b.WriteString("- Look at the diff to understand what changed in dependency files (package.json, go.mod, requirements.txt, etc.)\n")
	b.WriteString("- Check if the repo has a CHANGELOG.md or similar that references these dependencies\n")
	b.WriteString("- Identify any breaking changes based on the version bump type (major = likely breaking)\n\n")

	b.WriteString("### 3. Find Impacted Code Paths\n")
	b.WriteString("- Search the codebase for imports/usage of each updated dependency\n")
	b.WriteString("- Flag if any usage patterns might be affected by the update\n")
	b.WriteString("- Pay special attention to deprecated APIs or changed function signatures\n\n")

	b.WriteString("### 4. Run the Test Suite\n")
	b.WriteString("- Look for test configuration (package.json scripts, Makefile, go test, pytest, etc.)\n")
	b.WriteString("- Run the appropriate test command\n")
	b.WriteString("- Report results: pass/fail, any new failures, number of tests run\n\n")

	b.WriteString("### 5. Provide a Recommendation\n")
	b.WriteString("- Based on your analysis, recommend: **safe to merge**, **needs review**, or **potential issues found**\n")
	b.WriteString("- Explain your reasoning\n\n")

	b.WriteString("## Output Format\n")
	b.WriteString("Format your response as a structured review in GitHub-flavored markdown with clear sections.\n")
	b.WriteString("Be thorough but concise. Focus on actionable findings.\n")
	b.WriteString("Do NOT include these instructions in your response.\n")

	return b.String()
}
