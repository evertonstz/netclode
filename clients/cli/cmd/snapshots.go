package cmd

import (
	"context"
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/angristan/netclode/clients/cli/internal/client"
	"github.com/angristan/netclode/clients/cli/internal/output"
	pb "github.com/angristan/netclode/services/control-plane/gen/netclode/v1"
	"github.com/spf13/cobra"
)

var snapshotsCmd = &cobra.Command{
	Use:   "snapshots",
	Short: "Manage session snapshots",
	Long:  "List and restore session snapshots for history navigation.",
}

var snapshotsListCmd = &cobra.Command{
	Use:   "list <session-id>",
	Short: "List snapshots for a session",
	Args:  cobra.ExactArgs(1),
	RunE:  runSnapshotsList,
}

var snapshotsRestoreCmd = &cobra.Command{
	Use:   "restore <session-id> <snapshot-id>",
	Short: "Restore a session to a snapshot",
	Args:  cobra.ExactArgs(2),
	RunE:  runSnapshotsRestore,
}

func init() {
	rootCmd.AddCommand(snapshotsCmd)
	snapshotsCmd.AddCommand(snapshotsListCmd)
	snapshotsCmd.AddCommand(snapshotsRestoreCmd)
}

func runSnapshotsList(cmd *cobra.Command, args []string) error {
	ctx := context.Background()
	c := client.New(getServerURL())
	sessionID := args[0]

	snapshots, err := c.ListSnapshots(ctx, sessionID)
	if err != nil {
		return fmt.Errorf("list snapshots: %w", err)
	}

	if isJSONOutput() {
		return output.JSON(snapshots)
	}

	if len(snapshots) == 0 {
		fmt.Println("No snapshots found.")
		return nil
	}

	printSnapshotsTable(snapshots)
	return nil
}

func printSnapshotsTable(snapshots []*pb.Snapshot) {
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)

	_, _ = output.HeaderColor.Fprintf(w, "ID\tTURN\tNAME\tMSGS\tCREATED\n")

	for _, s := range snapshots {
		id := output.Truncate(s.Id, 16)
		name := output.Truncate(s.Name, 40)
		turn := fmt.Sprintf("%d", s.TurnNumber)
		msgs := fmt.Sprintf("%d", s.MessageCount)
		created := output.RelativeTime(s.CreatedAt)

		_, _ = output.IDColor.Fprintf(w, "%s\t", id)
		_, _ = fmt.Fprintf(w, "%s\t", turn)
		_, _ = output.NameColor.Fprintf(w, "%s\t", name)
		_, _ = fmt.Fprintf(w, "%s\t", msgs)
		_, _ = output.TimeColor.Fprintf(w, "%s\n", created)
	}

	_ = w.Flush()
}

func runSnapshotsRestore(cmd *cobra.Command, args []string) error {
	ctx := context.Background()
	c := client.New(getServerURL())
	sessionID := args[0]
	snapshotID := args[1]

	if err := c.RestoreSnapshot(ctx, sessionID, snapshotID); err != nil {
		return fmt.Errorf("restore snapshot: %w", err)
	}

	if isJSONOutput() {
		return output.JSON(map[string]string{
			"restored":   snapshotID,
			"session_id": sessionID,
		})
	}

	_, _ = output.SuccessColor.Printf("Restored session %s to snapshot %s\n", sessionID, snapshotID)
	return nil
}
