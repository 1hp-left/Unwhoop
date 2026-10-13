# Unwhoop native dashboard

The user requested a close visual reference to the WHOOP app and explicitly
asked to skip design drafts and implement directly.

Reference: WHOOP's published mobile dashboard, with separate Sleep, Recovery,
and Strain dials, a dark navy background, and compact health cards.
https://support.whoop.com/s/article/Navigating-the-WHOOP-Mobile-App?language=en_US

Use native SwiftUI, SF Symbols, and system type. Keep UNWHOOP as the app name.
Sleep uses lavender, recovery uses semantic lime/yellow/red, strain uses blue.
AppTheme defines the shared background, card, inset, and secondary text colors.

Home begins with the date and three dials, followed by the operational sync
card, a two-column Health Monitor, and My Day. Data contains connection status,
exports, and settings; Trends contains the existing date-range charts.

Missing scores show a dash and an explanation. Never fabricate measurements,
stress scores, coaching, or progress. Sync shows actual stages and records;
successful completion requires saved data. Keep partial transfers distinct.
