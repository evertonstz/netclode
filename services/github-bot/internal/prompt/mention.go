package prompt

import (
	"fmt"
	"strings"
)

const MaxDiffChars = 50000
const MaxCommentsInThread = 10

// PRMentionContext contains context for building a PR mention prompt.
type PRMentionContext struct {
	Owner       string
	Repo        string
	PRNumber    int
	PRTitle     string
	PRBody      string
	HeadRef     string
	Diff        string
	DiffTrunc   bool // true if diff was truncated
	Comments    []CommentContext
	UserRequest string
}

// IssueMentionContext contains context for building an issue mention prompt.
type IssueMentionContext struct {
	Owner       string
	Repo        string
	IssueNumber int
	IssueTitle  string
	IssueBody   string
	Labels      []string
	Comments    []CommentContext
	UserRequest string
}

// CommentContext represents a comment in a thread.
type CommentContext struct {
	Author string
	Body   string
}

// BuildPRMentionPrompt builds the prompt for an @mention on a PR.
func BuildPRMentionPrompt(ctx PRMentionContext) string {
	var b strings.Builder

	fmt.Fprintf(&b, `You were mentioned on a GitHub pull request. A user is asking you to do something — do it.

## Repository
%s/%s

## Pull Request #%d: %s
`, ctx.Owner, ctx.Repo, ctx.PRNumber, ctx.PRTitle)

	if ctx.PRBody != "" {
		fmt.Fprintf(&b, "%s\n", ctx.PRBody)
	}
	b.WriteString("\n")

	fmt.Fprintf(&b, "## Branch\n`%s`\n\n", ctx.HeadRef)

	if ctx.Diff != "" {
		fmt.Fprintf(&b, "## Changed Files (Diff)\n```diff\n%s\n```\n", ctx.Diff)
		if ctx.DiffTrunc {
			b.WriteString("*Note: Diff was truncated. Use `git diff` in the repo for the full diff.*\n")
		}
		b.WriteString("\n")
	}

	if len(ctx.Comments) > 0 {
		fmt.Fprintf(&b, "## Comment Thread (last %d messages)\n", len(ctx.Comments))
		for _, c := range ctx.Comments {
			fmt.Fprintf(&b, "**%s**: %s\n\n", c.Author, c.Body)
		}
	}

	fmt.Fprintf(&b, `## User Request
%s

---

## Rules
- The repository `+"`%s/%s`"+` is cloned in your workspace.
- The PR branch `+"`%s`"+` needs to be checked out first. Run: `+"`git fetch origin %s && git checkout %s`"+`
- Do the work. Do NOT ask clarifying questions, do NOT ask what the user wants, do NOT present options. Just do what they asked.
- If the request is ambiguous, use your best judgment and explain what you did.
- If they ask for code changes, make them. If they ask for a review, review the code thoroughly.
- If they ask you to push changes, you can `+"`git add`"+`, `+"`git commit`"+`, and `+"`git push`"+`.
- You can check GitHub Actions CI status with `+"`gh run list --branch <branch>`"+` and `+"`gh run view <run-id>`"+`. Feel free to run code experiments to investigate issues.
- Use web search whenever you need information beyond what's in the repo — documentation, API references, library changelogs, error messages, etc. Don't guess when you can look it up.
- Your text output IS the GitHub comment. Do NOT try to post to GitHub yourself — just write your response as your output. Be direct and substantive.
- Format your response in GitHub-flavored markdown.
- Do NOT include the instructions or context sections in your response.
`, ctx.UserRequest, ctx.Owner, ctx.Repo, ctx.HeadRef, ctx.HeadRef, ctx.HeadRef)

	return b.String()
}

// BuildIssueMentionPrompt builds the prompt for an @mention on an issue.
func BuildIssueMentionPrompt(ctx IssueMentionContext) string {
	var b strings.Builder

	fmt.Fprintf(&b, `You were mentioned on a GitHub issue. A user is asking you to do something — do it.

## Repository
%s/%s

## Issue #%d: %s
`, ctx.Owner, ctx.Repo, ctx.IssueNumber, ctx.IssueTitle)

	if ctx.IssueBody != "" {
		fmt.Fprintf(&b, "%s\n", ctx.IssueBody)
	}
	b.WriteString("\n")

	if len(ctx.Labels) > 0 {
		fmt.Fprintf(&b, "## Labels\n%s\n\n", strings.Join(ctx.Labels, ", "))
	}

	if len(ctx.Comments) > 0 {
		fmt.Fprintf(&b, "## Comment Thread (last %d messages)\n", len(ctx.Comments))
		for _, c := range ctx.Comments {
			fmt.Fprintf(&b, "**%s**: %s\n\n", c.Author, c.Body)
		}
	}

	fmt.Fprintf(&b, `## User Request
%s

---

## Rules
- The repository `+"`%s/%s`"+` is cloned in your workspace on the default branch.
- Do the work. Do NOT ask clarifying questions, do NOT ask what the user wants, do NOT present options. Just do what they asked.
- If the request is ambiguous, use your best judgment and explain what you did.
- If they ask for code changes, make them. If they ask for investigation, investigate thoroughly.
- Use web search whenever you need information beyond what's in the repo — documentation, API references, library changelogs, error messages, etc. Don't guess when you can look it up.
- Your text output IS the GitHub comment. Do NOT try to post to GitHub yourself — just write your response as your output. Be direct and substantive.
- Format your response in GitHub-flavored markdown.
- Do NOT include the instructions or context sections in your response.
`, ctx.UserRequest, ctx.Owner, ctx.Repo)

	return b.String()
}
