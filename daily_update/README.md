# Daily Paper Update Agent (PowerShell)

Automatically searches arXiv and Semantic Scholar for papers matching your research interests and sends a daily email digest. **No Python installation required** - runs natively on Windows PowerShell.

## Quick Start

1. Configure your Gmail credentials in `config.json`

2. Test the setup:
   ```powershell
   .\daily_update.ps1 -Test
   ```

3. Set up the daily scheduler (run as Administrator):
   ```
   setup_scheduler.bat
   ```

## Configuration

### Gmail App Password Setup

To send emails through Gmail, you need to create an App Password:

1. Go to your Google Account: https://myaccount.google.com/
2. Navigate to **Security** → **2-Step Verification** (enable if not already)
3. At the bottom, click **App passwords**
4. Select "Mail" and "Windows Computer"
5. Click **Generate**
6. Copy the 16-character password

### config.json

Edit `config.json` with your settings:

```json
{
  "email": {
    "smtp_server": "smtp.gmail.com",
    "smtp_port": 587,
    "sender_email": "your.email@gmail.com",
    "sender_password": "your-16-char-app-password",
    "recipient_email": "kleinl@biu.ac.il"
  },
  "research_config_path": "../research_interests_agent_config.md",
  "max_papers": 15,
  "min_relevance_score": 2,
  "arxiv_categories": [
    "cond-mat.mes-hall",
    "cond-mat.mtrl-sci",
    "physics.app-ph"
  ],
  "lookback_hours": 48
}
```

### Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `smtp_server` | SMTP server address | smtp.gmail.com |
| `smtp_port` | SMTP port | 587 |
| `sender_email` | Your Gmail address | - |
| `sender_password` | Gmail App Password | - |
| `recipient_email` | Where to send the digest | kleinl@biu.ac.il |
| `research_config_path` | Path to research interests file | ../research_interests_agent_config.md |
| `max_papers` | Maximum papers in digest | 15 |
| `min_relevance_score` | Minimum score to include paper | 2 |
| `arxiv_categories` | arXiv categories to search | cond-mat.mes-hall, cond-mat.mtrl-sci, physics.app-ph |
| `lookback_hours` | How far back to search | 48 |

## Usage

### Manual Run

Open PowerShell and navigate to the script directory:

```powershell
cd "C:\Users\kleinl\OneDrive - Bar Ilan University\Documents\High AI\daily_update"

# Send the daily digest
.\daily_update.ps1

# Test mode (fetch papers, no email)
.\daily_update.ps1 -Test

# Dry run (format email, don't send)
.\daily_update.ps1 -DryRun
```

If you get an execution policy error, run:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### Scheduled Run

Run `setup_scheduler.bat` as Administrator to create a Windows Task Scheduler entry that runs at 11:30 Israel time daily.

To manage the scheduled task:
```cmd
# Run task manually
schtasks /run /tn "DailyPaperUpdate"

# Check task status
schtasks /query /tn "DailyPaperUpdate"

# Delete task
schtasks /delete /tn "DailyPaperUpdate" /f
```

## Relevance Scoring

Papers are scored based on keyword matches:

| Match Type | Points |
|------------|--------|
| Primary keyword in title | +3 |
| Primary keyword in abstract | +2 |
| Related term anywhere | +1 |

Papers with a score >= 2 (configurable) are included in the digest.

## Troubleshooting

### "Running scripts is disabled on this system"
Run this command in PowerShell as Administrator:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### "SMTP Authentication failed" or email errors
- Make sure you're using an App Password, not your regular Gmail password
- Verify 2-Step Verification is enabled on your Google account
- Check that the sender_email matches the account that generated the App Password

### "No relevant papers found"
- Check that your `research_interests_agent_config.md` has keywords defined
- Try lowering `min_relevance_score` in config.json
- Expand `lookback_hours` to search further back

### Task Scheduler not running
- Ensure the task is set to run whether user is logged on or not
- Check Task Scheduler History for error messages
- Try running the script manually first to verify it works

## Files

```
daily_update/
├── daily_update.ps1     # Main PowerShell script
├── daily_update.py      # Python version (optional, requires Python)
├── config.json          # Configuration file
├── requirements.txt     # Python dependencies (only for .py version)
├── setup_scheduler.bat  # Task Scheduler setup
└── README.md            # This file
```

## Research Interests

Keywords and related terms are loaded from `research_interests_agent_config.md` in the parent directory. The file should contain sections like:

```markdown
## Research Interest 1: Spintronics

### Keywords
- spintronics
- spin electronics
- spin-based devices

### Related Terms
- spin valve
- giant magnetoresistance (GMR)
```
