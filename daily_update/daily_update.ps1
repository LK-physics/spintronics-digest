<#
.SYNOPSIS
    Daily Paper Update Agent - PowerShell Version
.DESCRIPTION
    Searches arXiv and Semantic Scholar for papers matching research interests
    and sends an email digest.
.PARAMETER Test
    Test mode: fetch papers and display results without sending email
.PARAMETER DryRun
    Dry run: fetch papers and format email but don't send
.PARAMETER Config
    Path to configuration file (default: config.json in script directory)
#>

param(
    [switch]$Test,
    [switch]$DryRun,
    [string]$Config = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

#region Logging

$script:LogFile = $null

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line
    if ($script:LogFile) {
        try {
            Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
        } catch {}
    }
}

#endregion

#region Configuration Loading

function Load-JsonConfig {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Config file not found: $Path"
    }

    $content = Get-Content -Path $Path -Raw -Encoding UTF8
    $parsed = $content | ConvertFrom-Json
    return $parsed
}

function Load-ResearchConfig {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Research config file not found: $Path"
    }

    $content = Get-Content -Path $Path -Raw -Encoding UTF8

    $keywords = @()
    $relatedTerms = @()

    # Extract keywords from ### Keywords sections
    $keywordMatches = [regex]::Matches($content, '### Keywords\r?\n(.*?)(?=\r?\n###|\r?\n---|\r?\n## |$)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    foreach ($match in $keywordMatches) {
        $section = $match.Groups[1].Value
        $items = [regex]::Matches($section, '^- (.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        foreach ($item in $items) {
            $keyword = $item.Groups[1].Value.Trim().ToLower()
            if ($keyword -and $keywords -notcontains $keyword) {
                $keywords += $keyword
            }
        }
    }

    # Extract related terms from ### Related Terms sections
    $relatedMatches = [regex]::Matches($content, '### Related Terms\r?\n(.*?)(?=\r?\n###|\r?\n---|\r?\n## |$)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    foreach ($match in $relatedMatches) {
        $section = $match.Groups[1].Value
        $items = [regex]::Matches($section, '^- (.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        foreach ($item in $items) {
            $term = $item.Groups[1].Value.Trim().ToLower()
            if ($term -and $relatedTerms -notcontains $term) {
                $relatedTerms += $term
            }
        }
    }

    Write-Log "Loaded $($keywords.Count) keywords and $($relatedTerms.Count) related terms"

    return @{
        Keywords = $keywords
        RelatedTerms = $relatedTerms
    }
}

#endregion

#region Paper Class

class Paper {
    [string]$Title
    [string[]]$Authors
    [string]$Abstract
    [string]$Url
    [string]$Source
    [datetime]$Published
    [string]$ArxivId
    [int]$RelevanceScore
    [string[]]$MatchedKeywords

    Paper() {
        $this.Authors = @()
        $this.MatchedKeywords = @()
        $this.RelevanceScore = 0
    }
}

#endregion

#region ArXiv Fetcher

function Parse-ArxivFeed {
    param(
        [string]$XmlContent,
        [datetime]$CutoffTime
    )

    $papers = @()
    [xml]$feed = $XmlContent

    $ns = New-Object System.Xml.XmlNamespaceManager($feed.NameTable)
    $ns.AddNamespace("atom", "http://www.w3.org/2005/Atom")

    $entries = $feed.SelectNodes("//atom:entry", $ns)

    foreach ($entry in $entries) {
        $getId = $entry.SelectSingleNode("atom:id", $ns)
        $getPublished = $entry.SelectSingleNode("atom:published", $ns)
        $getTitle = $entry.SelectSingleNode("atom:title", $ns)
        $getSummary = $entry.SelectSingleNode("atom:summary", $ns)

        $published = $null
        if ($getPublished) {
            try {
                $published = [datetime]::Parse($getPublished.InnerText)
            } catch {
                continue
            }
        }

        if ($published -and $published -lt $CutoffTime) {
            continue
        }

        $arxivId = ""
        $idText = if ($getId) { $getId.InnerText } else { "" }
        if ($idText -match 'arxiv.org/abs/(.+)$') {
            $arxivId = $Matches[1]
        }

        $authors = @()
        $authorNodes = $entry.SelectNodes("atom:author", $ns)
        foreach ($author in $authorNodes) {
            $nameNode = $author.SelectSingleNode("atom:name", $ns)
            if ($nameNode) {
                $authors += $nameNode.InnerText
            }
        }

        $titleText = if ($getTitle) { ($getTitle.InnerText -replace '\s+', ' ').Trim() } else { "" }
        $abstractText = if ($getSummary) { ($getSummary.InnerText -replace '\s+', ' ').Trim() } else { "" }

        $paperUrl = $idText
        $linkNodes = $entry.SelectNodes("atom:link", $ns)
        foreach ($link in $linkNodes) {
            if ($link.GetAttribute("type") -eq "text/html" -or $link.GetAttribute("rel") -eq "alternate") {
                $href = $link.GetAttribute("href")
                if ($href) {
                    $paperUrl = $href
                    break
                }
            }
        }

        $paper = [Paper]::new()
        $paper.Title = $titleText
        $paper.Authors = $authors
        $paper.Abstract = $abstractText
        $paper.Url = $paperUrl
        $paper.Source = "arXiv"
        $paper.Published = $published
        $paper.ArxivId = $arxivId

        $papers += $paper
    }

    return $papers
}

function Fetch-ArxivPapers {
    param(
        [string[]]$Categories,
        [int]$LookbackHours = 168
    )

    $papers = @()
    $cutoffTime = (Get-Date).AddHours(-$LookbackHours)

    # Build category query part
    $catQuery = ($Categories | ForEach-Object { "cat:$_" }) -join "+OR+"

    # Build keyword query for title/abstract search
    $titleKeywords = @("spintronics", "MRAM", "spin-orbit+torque", "magnetic+sensor", "skyrmion", "magnetic+tunnel+junction", "magnetoresistance", "spin+current")
    $kwQuery = ($titleKeywords | ForEach-Object { "ti:$_" }) -join "+OR+"

    # Primary query: keywords AND categories
    $primaryQuery = "($kwQuery)+AND+($catQuery)"
    $url = "http://export.arxiv.org/api/query?search_query=$primaryQuery&start=0&max_results=200&sortBy=submittedDate&sortOrder=descending"

    Write-Log "Fetching arXiv papers (keyword+category query)..."

    try {
        $response = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 60 -UseBasicParsing
        $papers = Parse-ArxivFeed -XmlContent $response.Content -CutoffTime $cutoffTime
        Write-Log "Primary arXiv query returned $($papers.Count) papers within lookback window"
    }
    catch {
        Write-Log "Error in primary arXiv query: $_" "ERROR"
    }

    # Fallback: if 0 papers, try keyword-only search (no category filter)
    if ($papers.Count -eq 0) {
        Write-Log "No papers from primary query, trying keyword-only fallback..."
        $fallbackUrl = "http://export.arxiv.org/api/query?search_query=$kwQuery&start=0&max_results=100&sortBy=submittedDate&sortOrder=descending"
        try {
            $response = Invoke-WebRequest -Uri $fallbackUrl -Method Get -TimeoutSec 60 -UseBasicParsing
            $papers = Parse-ArxivFeed -XmlContent $response.Content -CutoffTime $cutoffTime
            Write-Log "Fallback arXiv query returned $($papers.Count) papers"
        }
        catch {
            Write-Log "Error in fallback arXiv query: $_" "ERROR"
        }
    }

    Write-Log "Fetched $($papers.Count) total papers from arXiv"
    return $papers
}

#endregion

#region Semantic Scholar Fetcher

function Fetch-SemanticScholarPapers {
    param(
        [string[]]$Keywords,
        [int]$LookbackHours = 168,
        [string]$ApiKey = ""
    )

    $papers = @()
    $seenIds = @{}

    # Use top 3 keywords to reduce rate-limit risk
    $searchKeywords = $Keywords | Select-Object -First 3

    # Calculate date range
    $endDate = Get-Date
    $startDate = $endDate.AddHours(-$LookbackHours)
    $dateRange = "$($startDate.ToString('yyyy-MM-dd')):$($endDate.ToString('yyyy-MM-dd'))"

    Write-Log "Fetching Semantic Scholar papers for $($searchKeywords.Count) keywords (date range: $dateRange)..."

    # Headers for Semantic Scholar API
    $headers = @{
        "Accept" = "application/json"
        "User-Agent" = "DailyPaperUpdateAgent/1.0 (Academic Research Tool; kleinl@biu.ac.il)"
    }
    if ($ApiKey -and $ApiKey -ne "") {
        $headers["x-api-key"] = $ApiKey
        Write-Log "Using Semantic Scholar API key"
    }

    foreach ($keyword in $searchKeywords) {
        $maxRetries = 1
        $retryCount = 0
        $success = $false

        while (-not $success -and $retryCount -le $maxRetries) {
            try {
                # Rate limit: wait before each request (2s without key, 500ms with key)
                $delay = if ($ApiKey -and $ApiKey -ne "") { 500 } else { 2000 }
                Start-Sleep -Milliseconds $delay

                $encodedKeyword = [System.Web.HttpUtility]::UrlEncode($keyword)
                $url = "https://api.semanticscholar.org/graph/v1/paper/search?query=$encodedKeyword&limit=50&fields=title,authors,abstract,url,publicationDate,externalIds&publicationDateOrYear=$dateRange"

                $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30 -Headers $headers

                if ($response.data) {
                    foreach ($item in $response.data) {
                        $paperId = $item.paperId
                        if ($seenIds.ContainsKey($paperId)) {
                            continue
                        }
                        $seenIds[$paperId] = $true

                        $published = Get-Date
                        if ($item.publicationDate) {
                            try {
                                $published = [datetime]::Parse($item.publicationDate)
                            } catch {}
                        }

                        $authors = @()
                        if ($item.authors) {
                            foreach ($author in $item.authors) {
                                if ($author.name) {
                                    $authors += $author.name
                                }
                            }
                        }

                        $paperUrl = $item.url
                        if ($item.externalIds) {
                            if ($item.externalIds.ArXiv) {
                                $paperUrl = "https://arxiv.org/abs/$($item.externalIds.ArXiv)"
                            } elseif ($item.externalIds.DOI) {
                                $paperUrl = "https://doi.org/$($item.externalIds.DOI)"
                            }
                        }

                        $paper = [Paper]::new()
                        $paper.Title = if ($item.title) { $item.title.Trim() } else { "" }
                        $paper.Authors = $authors
                        $paper.Abstract = if ($item.abstract) { $item.abstract } else { "" }
                        $paper.Url = $paperUrl
                        $paper.Source = "Semantic Scholar"
                        $paper.Published = $published

                        $papers += $paper
                    }
                }

                Write-Log "Keyword '$keyword': found $($response.total) results"
                $success = $true
            }
            catch {
                $statusCode = $null
                if ($_.Exception.Response) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }

                if ($statusCode -eq 429) {
                    $retryCount++
                    if ($retryCount -le $maxRetries) {
                        $backoff = 5000 * $retryCount
                        Write-Log "Rate limited (429) on '$keyword', retrying in $($backoff/1000)s..." "WARN"
                        Start-Sleep -Milliseconds $backoff
                    } else {
                        Write-Log "Rate limited on '$keyword' after $maxRetries retries, skipping remaining keywords" "WARN"
                        return $papers
                    }
                } else {
                    Write-Log "Error fetching '$keyword' from Semantic Scholar: $_" "ERROR"
                    $success = $true  # don't retry non-429 errors
                }
            }
        }
    }

    Write-Log "Fetched $($papers.Count) papers from Semantic Scholar"
    return $papers
}

#endregion

#region Relevance Scoring

function Score-Paper {
    param(
        [Paper]$Paper,
        [string[]]$Keywords,
        [string[]]$RelatedTerms
    )

    $titleLower = $Paper.Title.ToLower()
    $abstractLower = $Paper.Abstract.ToLower()

    $score = 0
    $matched = @{}

    # Check primary keywords
    foreach ($keyword in $Keywords) {
        if ($titleLower.Contains($keyword)) {
            $score += 3
            $matched[$keyword] = $true
        } elseif ($abstractLower.Contains($keyword)) {
            $score += 2
            $matched[$keyword] = $true
        }
    }

    # Check related terms
    foreach ($term in $RelatedTerms) {
        if (-not $matched.ContainsKey($term)) {
            if ($titleLower.Contains($term) -or $abstractLower.Contains($term)) {
                $score += 1
                $matched[$term] = $true
            }
        }
    }

    $Paper.RelevanceScore = $score
    $Paper.MatchedKeywords = $matched.Keys

    return $score
}

#endregion

#region Email Formatting

function Format-EmailHtml {
    param(
        [Paper[]]$Papers,
        [string]$DateStr,
        [int]$MaxPapers = 15
    )

    $subject = "Daily Paper Update - $DateStr"

    $htmlHead = @"
<!DOCTYPE html>
<html>
<head>
<style>
body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; max-width: 800px; margin: 0 auto; padding: 20px; }
h1 { color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: 10px; }
.paper { margin-bottom: 25px; padding: 15px; background: #f9f9f9; border-radius: 8px; border-left: 4px solid #3498db; }
.paper-title { font-size: 1.1em; font-weight: bold; color: #2c3e50; margin-bottom: 8px; }
.paper-title a { color: #2c3e50; text-decoration: none; }
.paper-title a:hover { color: #3498db; text-decoration: underline; }
.paper-meta { font-size: 0.9em; color: #666; margin-bottom: 8px; }
.paper-keywords { font-size: 0.85em; color: #27ae60; margin-bottom: 8px; }
.paper-abstract { font-size: 0.9em; color: #555; }
.score { display: inline-block; background: #3498db; color: white; padding: 2px 8px; border-radius: 4px; font-size: 0.8em; }
.footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #ddd; font-size: 0.85em; color: #888; }
</style>
</head>
<body>
<h1>Daily Paper Update - $DateStr</h1>
<p>Found <strong>$($Papers.Count)</strong> relevant papers from the last 7 days.</p>
"@

    $htmlPapers = ""
    $count = 0

    foreach ($paper in $Papers) {
        $count++
        if ($count -gt $MaxPapers) { break }

        # Format authors
        $authorsDisplay = ($paper.Authors | Select-Object -First 5) -join ", "
        if ($paper.Authors.Count -gt 5) {
            $authorsDisplay += " et al. ($($paper.Authors.Count) authors)"
        }

        # Truncate abstract
        $abstract = $paper.Abstract
        if ($abstract.Length -gt 400) {
            $abstract = $abstract.Substring(0, 400) + "..."
        }

        # Format keywords
        $keywordsDisplay = if ($paper.MatchedKeywords.Count -gt 0) {
            ($paper.MatchedKeywords | Select-Object -First 5) -join ", "
        } else {
            "General match"
        }

        # Format published date
        $publishedStr = ""
        if ($paper.Published) {
            $publishedStr = " | <strong>Published:</strong> $($paper.Published.ToString('yyyy-MM-dd'))"
        }

        $htmlPapers += @"

<div class="paper">
    <div class="paper-title">
        $count. <a href="$($paper.Url)" target="_blank">$($paper.Title)</a>
        <span class="score">Score: $($paper.RelevanceScore)</span>
    </div>
    <div class="paper-meta">
        <strong>Authors:</strong> $authorsDisplay<br>
        <strong>Source:</strong> $($paper.Source)$publishedStr
    </div>
    <div class="paper-keywords">
        <strong>Matched:</strong> $keywordsDisplay
    </div>
    <div class="paper-abstract">$abstract</div>
</div>
"@
    }

    $htmlFooter = @"

<div class="footer">
    <p>This digest was automatically generated by the Daily Paper Update Agent.<br>
    Research interests configured in: research_interests_agent_config.md</p>
</div>
</body>
</html>
"@

    $htmlBody = $htmlHead + $htmlPapers + $htmlFooter

    return @{
        Subject = $subject
        Body = $htmlBody
    }
}

#endregion

#region Email Sending

function Send-PaperEmail {
    param(
        [string]$SmtpServer,
        [int]$SmtpPort,
        [string]$SenderEmail,
        [string]$SenderPassword,
        [string]$RecipientEmail,
        [string]$Subject,
        [string]$HtmlBody
    )

    try {
        # Create credentials
        $securePassword = ConvertTo-SecureString $SenderPassword -AsPlainText -Force
        $credentials = New-Object System.Management.Automation.PSCredential($SenderEmail, $securePassword)

        # Create mail message using .NET classes for better HTML support
        $smtp = New-Object System.Net.Mail.SmtpClient($SmtpServer, $SmtpPort)
        $smtp.EnableSsl = $true
        $smtp.Credentials = New-Object System.Net.NetworkCredential($SenderEmail, $SenderPassword)

        $mail = New-Object System.Net.Mail.MailMessage
        $mail.From = $SenderEmail
        $mail.To.Add($RecipientEmail)
        $mail.Subject = $Subject
        $mail.Body = $HtmlBody
        $mail.IsBodyHtml = $true

        $smtp.Send($mail)

        Write-Log "Email sent successfully to $RecipientEmail"
        return $true
    }
    catch {
        Write-Log "Error sending email: $_" "ERROR"
        if ($_.Exception.Message -match "authentication|credential|password") {
            Write-Log "For Gmail, make sure you're using an App Password, not your regular password." "WARN"
        }
        return $false
    }
}

#endregion

#region Main

# Load System.Web for URL encoding
Add-Type -AssemblyName System.Web | Out-Null

# Determine config path
if ([string]::IsNullOrEmpty($Config)) {
    $configPath = Join-Path $ScriptDir "config.json"
} elseif (-not [System.IO.Path]::IsPathRooted($Config)) {
    $configPath = Join-Path $ScriptDir $Config
} else {
    $configPath = $Config
}

$configContent = Get-Content -Path $configPath -Raw -Encoding UTF8
$appConfig = ConvertFrom-Json -InputObject $configContent

# Initialize log file
$logFileName = if ($appConfig.logFile) { $appConfig.logFile } else { "daily_update.log" }
if (-not [System.IO.Path]::IsPathRooted($logFileName)) {
    $script:LogFile = Join-Path $ScriptDir $logFileName
} else {
    $script:LogFile = $logFileName
}

Write-Log "=== Daily Paper Update started ==="
Write-Log "Loading configuration from $configPath"

# Load research interests
$researchConfigPath = $appConfig.researchConfigPath
if ([string]::IsNullOrEmpty($researchConfigPath)) {
    $researchConfigPath = "../research_interests_agent_config.md"
}
if (-not [System.IO.Path]::IsPathRooted($researchConfigPath)) {
    $researchConfigPath = Join-Path $ScriptDir $researchConfigPath
}
$researchConfigPath = [System.IO.Path]::GetFullPath($researchConfigPath)

Write-Log "Loading research interests from $researchConfigPath"
$researchConfig = Load-ResearchConfig -Path $researchConfigPath

# Get settings
$arxivCategories = if ($appConfig.arxivCategories) { $appConfig.arxivCategories } else { @("cond-mat.mes-hall", "cond-mat.mtrl-sci", "physics.app-ph") }
$lookbackHours = if ($appConfig.lookbackHours) { $appConfig.lookbackHours } else { 168 }
$maxPapers = if ($appConfig.maxPapers) { $appConfig.maxPapers } else { 15 }
$minScore = if ($appConfig.minRelevanceScore) { $appConfig.minRelevanceScore } else { 2 }
$ssApiKey = if ($appConfig.semanticScholarApiKey) { $appConfig.semanticScholarApiKey } else { "" }

# Fetch papers
$allPapers = @()
$allPapers += Fetch-ArxivPapers -Categories $arxivCategories -LookbackHours $lookbackHours
$allPapers += Fetch-SemanticScholarPapers -Keywords $researchConfig.Keywords -LookbackHours $lookbackHours -ApiKey $ssApiKey

# Remove duplicates based on normalized title
$seenTitles = @{}
$uniquePapers = @()
foreach ($paper in $allPapers) {
    $normalized = ($paper.Title -replace '[^\w\s]', '').ToLower() -replace '\s+', ' '
    if (-not $seenTitles.ContainsKey($normalized)) {
        $seenTitles[$normalized] = $true
        $uniquePapers += $paper
    }
}

Write-Log "Total unique papers: $($uniquePapers.Count)"

# Score papers
foreach ($paper in $uniquePapers) {
    Score-Paper -Paper $paper -Keywords $researchConfig.Keywords -RelatedTerms $researchConfig.RelatedTerms | Out-Null
}

# Filter by minimum score
$relevantPapers = $uniquePapers | Where-Object { $_.RelevanceScore -ge $minScore }

# Sort by relevance score (descending)
$relevantPapers = $relevantPapers | Sort-Object -Property RelevanceScore -Descending

Write-Log "Papers with relevance score >= ${minScore}: $($relevantPapers.Count)"

# Test mode
if ($Test) {
    Write-Host ""
    Write-Host ("=" * 60)
    Write-Host "TEST MODE - Top papers found:"
    Write-Host ("=" * 60)

    $count = 0
    foreach ($paper in $relevantPapers) {
        $count++
        if ($count -gt 15) { break }

        Write-Host ""
        Write-Host "$count. [$($paper.RelevanceScore)] $($paper.Title)"
        Write-Host "   Authors: $(($paper.Authors | Select-Object -First 3) -join ', ')"
        Write-Host "   Keywords: $(($paper.MatchedKeywords | Select-Object -First 5) -join ', ')"
        Write-Host "   URL: $($paper.Url)"
    }

    exit 0
}

# Check if we have papers
if ($relevantPapers.Count -eq 0) {
    Write-Log "No relevant papers found for today. Skipping email."
    Write-Log "=== Daily Paper Update finished (no papers) ==="
    exit 0
}

# Format email
$dateStr = (Get-Date).ToString("MMMM dd, yyyy")
$email = Format-EmailHtml -Papers $relevantPapers -DateStr $dateStr -MaxPapers $maxPapers

# Dry run mode
if ($DryRun) {
    Write-Host ""
    Write-Host ("=" * 60)
    Write-Host "DRY RUN - Email would be sent:"
    Write-Host ("=" * 60)
    Write-Host "Subject: $($email.Subject)"
    Write-Host "Papers: $(([Math]::Min($relevantPapers.Count, $maxPapers)))"
    Write-Host ""
    Write-Host "To actually send the email, run without -DryRun flag."
    exit 0
}

# Validate email configuration
if ($appConfig.senderEmail -match "^YOUR_") {
    Write-Log "ERROR: Please configure your email settings in config.json" "ERROR"
    Write-Log "See README.md for setup instructions."
    exit 1
}

# Send email
$success = Send-PaperEmail `
    -SmtpServer $appConfig.smtpServer `
    -SmtpPort $appConfig.smtpPort `
    -SenderEmail $appConfig.senderEmail `
    -SenderPassword $appConfig.senderPassword `
    -RecipientEmail $appConfig.recipientEmail `
    -Subject $email.Subject `
    -HtmlBody $email.Body

if ($success) {
    Write-Log "Daily paper update completed successfully!"
    Write-Log "=== Daily Paper Update finished (success) ==="
    exit 0
} else {
    Write-Log "Failed to send email." "ERROR"
    Write-Log "=== Daily Paper Update finished (email failed) ==="
    exit 1
}

#endregion
