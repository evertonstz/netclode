package cmd

import (
	"fmt"
	"time"

	"github.com/angristan/netclode/clients/cli/internal/codex"
	"github.com/spf13/cobra"
)

var authCmd = &cobra.Command{
	Use:   "auth",
	Short: "Manage authentication",
	Long:  "Authenticate with various SDK providers.",
}

var authCodexCmd = &cobra.Command{
	Use:   "codex",
	Short: "Authenticate with ChatGPT for Codex SDK",
	Long: `Authenticate with ChatGPT using OAuth device code flow.

This command will:
1. Display a verification URL and code
2. Wait for you to authorize in your browser
3. Output tokens to add to your .env file

The tokens are then deployed to production via Ansible.`,
	RunE: runAuthCodex,
}

func init() {
	rootCmd.AddCommand(authCmd)
	authCmd.AddCommand(authCodexCmd)
}

func runAuthCodex(cmd *cobra.Command, args []string) error {
	fmt.Println("Codex Authentication (ChatGPT OAuth)")
	fmt.Println("=====================================")
	fmt.Println()

	// Step 1: Request device code
	fmt.Println("Requesting device code...")
	dc, err := codex.RequestDeviceCode()
	if err != nil {
		return fmt.Errorf("failed to request device code: %w", err)
	}

	fmt.Println()
	fmt.Printf("Visit:  %s\n", dc.VerificationURL)
	fmt.Printf("Code:   %s\n", dc.UserCode)
	fmt.Println()
	fmt.Println("Waiting for authorization (15 minute timeout)...")

	// Step 2: Poll for authorization
	ce, err := codex.PollForAuthorization(dc, 15*time.Minute)
	if err != nil {
		return fmt.Errorf("authorization failed: %w", err)
	}

	fmt.Println("Authorization received, exchanging for tokens...")

	// Step 3: Exchange for tokens
	tokens, err := codex.ExchangeCodeForTokens(ce)
	if err != nil {
		return fmt.Errorf("token exchange failed: %w", err)
	}

	fmt.Println()
	fmt.Println("Authentication successful!")
	fmt.Println()
	fmt.Println("Add these to your .env file:")
	fmt.Println("-----------------------------")
	fmt.Printf("CODEX_ACCESS_TOKEN=%s\n", tokens.AccessToken)
	fmt.Printf("CODEX_REFRESH_TOKEN=%s\n", tokens.RefreshToken)
	fmt.Printf("CODEX_ID_TOKEN=%s\n", tokens.IDToken)
	fmt.Println()
	fmt.Println("Then deploy with: cd infra/ansible && DEPLOY_HOST=<host> ansible-playbook playbooks/site.yaml")

	return nil
}
