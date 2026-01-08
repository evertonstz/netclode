import { createTheme, MantineColorsTuple } from "@mantine/core";

const peach: MantineColorsTuple = [
  "#FFF5F0",
  "#FFE8DB",
  "#FFD4BD",
  "#FFBF9E",
  "#FFA67F",
  "#F2BFA6", // warm-peach from original
  "#E67350",
  "#CC5A40",
  "#B34130",
  "#992820",
];

const lavender: MantineColorsTuple = [
  "#F8F5FF",
  "#EDE5FF",
  "#DFD0FF",
  "#D0BBFF",
  "#C1A6FF",
  "#B399CC", // cozy-lavender from original
  "#9980B3", // cozy-purple from original
  "#8A67CC",
  "#7652B3",
  "#623D99",
];

const sage: MantineColorsTuple = [
  "#F0FAF3",
  "#E0F5E8",
  "#C2EBD0",
  "#A3E0B8",
  "#85D6A0",
  "#99BFA6", // cozy-sage from original
  "#6BB37F",
  "#5A9969",
  "#498053",
  "#38663D",
];

const coral: MantineColorsTuple = [
  "#FFF0EE",
  "#FFE0DB",
  "#FFC4BC",
  "#FFA79C",
  "#FF8B7D",
  "#EB8073", // warm-coral from original
  "#D16359",
  "#B74940",
  "#9D2F26",
  "#82150D",
];

export const theme = createTheme({
  primaryColor: "peach",
  colors: {
    peach,
    lavender,
    sage,
    coral,
  },
  defaultRadius: "md",
  fontFamily:
    'ui-rounded, "SF Pro Rounded", system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
  headings: {
    fontFamily:
      'ui-rounded, "SF Pro Rounded", system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
  },
  other: {
    // Custom colors from original design
    warmPeach: "#F2BFA6",
    warmApricot: "#F29966",
    warmCoral: "#EB8073",
    cozyLavender: "#B399CC",
    cozyPurple: "#9980B3",
    cozySage: "#99BFA6",
    cozyTeal: "#80B3BF",
    gentleBlue: "#80A6CC",
    gentleGray: "#99999E",
    softCharcoal: "#404047",
  },
});
