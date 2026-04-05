<#
.SYNOPSIS
    Monthly Website Updater - Updates the Spintronics Monthly Digest website
.DESCRIPTION
    Fetches recent papers from arXiv and Semantic Scholar, fetches science news
    from RSS feeds, scores and ranks items, and updates the Papers and News
    sections of index.html while preserving Conferences and Calls sections.
.PARAMETER Test
    Test mode: fetch and display results without modifying index.html
.PARAMETER Config
    Path to configuration file (default: config.json in script directory)
#>

param(
    [switch]$Test,
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

#region Configuration

Add-Type -AssemblyName System.Web | Out-Null

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

Write-Log "=== Monthly Website Update started ==="

# Load research interests
$researchConfigPath = $appConfig.researchConfigPath
if ([string]::IsNullOrEmpty($researchConfigPath)) {
    $researchConfigPath = "../research_interests_agent_config.md"
}
if (-not [System.IO.Path]::IsPathRooted($researchConfigPath)) {
    $researchConfigPath = Join-Path $ScriptDir $researchConfigPath
}
$researchConfigPath = [System.IO.Path]::GetFullPath($researchConfigPath)

# Parse research config for keywords
function Load-ResearchConfig {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Research config not found: $Path" }
    $content = Get-Content -Path $Path -Raw -Encoding UTF8
    $keywords = @()
    $relatedTerms = @()
    $keywordMatches = [regex]::Matches($content, '### Keywords\r?\n(.*?)(?=\r?\n###|\r?\n---|\r?\n## |$)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    foreach ($match in $keywordMatches) {
        $section = $match.Groups[1].Value
        $items = [regex]::Matches($section, '^- (.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        foreach ($item in $items) {
            $keyword = $item.Groups[1].Value.Trim().ToLower()
            if ($keyword -and $keywords -notcontains $keyword) { $keywords += $keyword }
        }
    }
    $relatedMatches = [regex]::Matches($content, '### Related Terms\r?\n(.*?)(?=\r?\n###|\r?\n---|\r?\n## |$)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    foreach ($match in $relatedMatches) {
        $section = $match.Groups[1].Value
        $items = [regex]::Matches($section, '^- (.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        foreach ($item in $items) {
            $term = $item.Groups[1].Value.Trim().ToLower()
            if ($term -and $relatedTerms -notcontains $term) { $relatedTerms += $term }
        }
    }
    return @{ Keywords = $keywords; RelatedTerms = $relatedTerms }
}

$researchConfig = Load-ResearchConfig -Path $researchConfigPath
Write-Log "Loaded $($researchConfig.Keywords.Count) keywords, $($researchConfig.RelatedTerms.Count) related terms"

$arxivCategories = if ($appConfig.arxivCategories) { $appConfig.arxivCategories } else { @("cond-mat.mes-hall", "cond-mat.mtrl-sci", "physics.app-ph") }
$ssApiKey = if ($appConfig.semanticScholarApiKey) { $appConfig.semanticScholarApiKey } else { "" }

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

#region ArXiv Fetcher (for monthly: 30-day lookback)

function Parse-ArxivFeed {
    param([string]$XmlContent, [datetime]$CutoffTime)
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
            try { $published = [datetime]::Parse($getPublished.InnerText) } catch { continue }
        }
        if ($published -and $published -lt $CutoffTime) { continue }
        $arxivId = ""
        $idText = if ($getId) { $getId.InnerText } else { "" }
        if ($idText -match 'arxiv.org/abs/(.+)$') { $arxivId = $Matches[1] }
        $authors = @()
        $authorNodes = $entry.SelectNodes("atom:author", $ns)
        foreach ($author in $authorNodes) {
            $nameNode = $author.SelectSingleNode("atom:name", $ns)
            if ($nameNode) { $authors += $nameNode.InnerText }
        }
        $titleText = if ($getTitle) { ($getTitle.InnerText -replace '\s+', ' ').Trim() } else { "" }
        $abstractText = if ($getSummary) { ($getSummary.InnerText -replace '\s+', ' ').Trim() } else { "" }
        $paperUrl = $idText
        $linkNodes = $entry.SelectNodes("atom:link", $ns)
        foreach ($link in $linkNodes) {
            if ($link.GetAttribute("type") -eq "text/html" -or $link.GetAttribute("rel") -eq "alternate") {
                $href = $link.GetAttribute("href")
                if ($href) { $paperUrl = $href; break }
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
    param([string[]]$Categories, [int]$LookbackDays = 30)
    $papers = @()
    $cutoffTime = (Get-Date).AddDays(-$LookbackDays)
    $catQuery = ($Categories | ForEach-Object { "cat:$_" }) -join "+OR+"
    $titleKeywords = @("spintronics", "MRAM", "spin-orbit+torque", "magnetic+sensor", "skyrmion", "magnetic+tunnel+junction", "magnetoresistance", "spin+current", "spin+pumping", "neuromorphic+magnetic")
    $kwQuery = ($titleKeywords | ForEach-Object { "ti:$_" }) -join "+OR+"
    $primaryQuery = "($kwQuery)+AND+($catQuery)"
    $url = "http://export.arxiv.org/api/query?search_query=$primaryQuery&start=0&max_results=200&sortBy=submittedDate&sortOrder=descending"
    Write-Log "Fetching arXiv papers (30-day lookback for monthly digest)..."
    try {
        $response = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 60 -UseBasicParsing
        $papers = Parse-ArxivFeed -XmlContent $response.Content -CutoffTime $cutoffTime
        Write-Log "ArXiv query returned $($papers.Count) papers"
    } catch {
        Write-Log "Error in arXiv query: $_" "ERROR"
    }
    if ($papers.Count -eq 0) {
        Write-Log "Trying keyword-only fallback..."
        $fallbackUrl = "http://export.arxiv.org/api/query?search_query=$kwQuery&start=0&max_results=100&sortBy=submittedDate&sortOrder=descending"
        try {
            $response = Invoke-WebRequest -Uri $fallbackUrl -Method Get -TimeoutSec 60 -UseBasicParsing
            $papers = Parse-ArxivFeed -XmlContent $response.Content -CutoffTime $cutoffTime
            Write-Log "Fallback returned $($papers.Count) papers"
        } catch {
            Write-Log "Error in fallback query: $_" "ERROR"
        }
    }
    return $papers
}

#endregion

#region Semantic Scholar Fetcher

function Fetch-SemanticScholarPapers {
    param([string[]]$Keywords, [int]$LookbackDays = 30, [string]$ApiKey = "")
    $papers = @()
    $seenIds = @{}
    $searchKeywords = $Keywords | Select-Object -First 3
    $endDate = Get-Date
    $startDate = $endDate.AddDays(-$LookbackDays)
    $dateRange = "$($startDate.ToString('yyyy-MM-dd')):$($endDate.ToString('yyyy-MM-dd'))"
    Write-Log "Fetching Semantic Scholar papers (date range: $dateRange)..."
    $headers = @{
        "Accept" = "application/json"
        "User-Agent" = "SpintronicsDigestUpdater/1.0 (Academic Research Tool; kleinl@biu.ac.il)"
    }
    if ($ApiKey -and $ApiKey -ne "") { $headers["x-api-key"] = $ApiKey }

    foreach ($keyword in $searchKeywords) {
        $maxRetries = 1; $retryCount = 0; $success = $false
        while (-not $success -and $retryCount -le $maxRetries) {
            try {
                $delay = if ($ApiKey -and $ApiKey -ne "") { 500 } else { 2000 }
                Start-Sleep -Milliseconds $delay
                $encodedKeyword = [System.Web.HttpUtility]::UrlEncode($keyword)
                $url = "https://api.semanticscholar.org/graph/v1/paper/search?query=$encodedKeyword&limit=50&fields=title,authors,abstract,url,publicationDate,externalIds&publicationDateOrYear=$dateRange"
                $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30 -Headers $headers
                if ($response.data) {
                    foreach ($item in $response.data) {
                        $paperId = $item.paperId
                        if ($seenIds.ContainsKey($paperId)) { continue }
                        $seenIds[$paperId] = $true
                        $published = Get-Date
                        if ($item.publicationDate) {
                            try { $published = [datetime]::Parse($item.publicationDate) } catch {}
                        }
                        $authors = @()
                        if ($item.authors) { foreach ($a in $item.authors) { if ($a.name) { $authors += $a.name } } }
                        $paperUrl = $item.url
                        if ($item.externalIds) {
                            if ($item.externalIds.ArXiv) { $paperUrl = "https://arxiv.org/abs/$($item.externalIds.ArXiv)" }
                            elseif ($item.externalIds.DOI) { $paperUrl = "https://doi.org/$($item.externalIds.DOI)" }
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
                Write-Log "SS keyword '$keyword': $($response.total) results"
                $success = $true
            } catch {
                $statusCode = $null
                if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
                if ($statusCode -eq 429) {
                    $retryCount++
                    if ($retryCount -le $maxRetries) {
                        $backoff = 5000 * $retryCount
                        Write-Log "Rate limited on '$keyword', retrying in $($backoff/1000)s..." "WARN"
                        Start-Sleep -Milliseconds $backoff
                    } else {
                        Write-Log "Rate limited after retries, skipping remaining" "WARN"
                        return $papers
                    }
                } else {
                    Write-Log "Error fetching '$keyword': $_" "ERROR"
                    $success = $true
                }
            }
        }
    }
    Write-Log "Fetched $($papers.Count) papers from Semantic Scholar"
    return $papers
}

#endregion

#region RSS News Fetcher

class NewsItem {
    [string]$Title
    [string]$Url
    [string]$Source
    [string]$Summary
    [datetime]$Published
    [int]$RelevanceScore
    [string[]]$MatchedKeywords

    NewsItem() {
        $this.MatchedKeywords = @()
        $this.RelevanceScore = 0
    }
}

function Fetch-RssNews {
    param([int]$LookbackDays = 30)

    $newsItems = @()
    $cutoffTime = (Get-Date).AddDays(-$LookbackDays)

    # RSS feeds relevant to spintronics
    $feeds = @(
        # Targeted spintronics/magnetics sources
        @{ Url = "https://www.spintronics-info.com/rss.xml"; Source = "Spintronics-Info" }
        @{ Url = "https://www.nature.com/nnano.rss"; Source = "Nature Nanotech" }
        @{ Url = "https://www.nature.com/natelectron.rss"; Source = "Nature Electronics" }
        @{ Url = "https://www.nature.com/nmat.rss"; Source = "Nature Materials" }
        # Broader physics/materials sources
        @{ Url = "https://phys.org/rss-feed/physics-news/condensed-matter/"; Source = "Phys.org" }
        @{ Url = "https://www.sciencedaily.com/rss/matter_energy/materials_science.xml"; Source = "ScienceDaily" }
        @{ Url = "https://www.sciencedaily.com/rss/matter_energy/quantum_computing.xml"; Source = "ScienceDaily" }
        @{ Url = "https://www.sciencedaily.com/rss/matter_energy/electronics.xml"; Source = "ScienceDaily" }
    )

    foreach ($feed in $feeds) {
        try {
            Write-Log "Fetching RSS from $($feed.Source): $($feed.Url)"
            $response = Invoke-WebRequest -Uri $feed.Url -Method Get -TimeoutSec 30 -UseBasicParsing
            [xml]$rss = $response.Content

            $items = $rss.rss.channel.item
            if (-not $items) { continue }

            foreach ($item in $items) {
                $published = $null
                if ($item.pubDate) {
                    try { $published = [datetime]::Parse($item.pubDate) } catch { continue }
                }
                if ($published -and $published -lt $cutoffTime) { continue }

                $newsItem = [NewsItem]::new()
                $newsItem.Title = if ($item.title) { ($item.title -replace '\s+', ' ').Trim() } else { "" }
                $newsItem.Url = if ($item.link) { $item.link.Trim() } else { "" }
                $newsItem.Source = $feed.Source

                # Get description/summary — handle different RSS formats
                $desc = ""
                $rawDesc = $null
                if ($item.description) {
                    # Some feeds return XmlElement instead of string
                    if ($item.description -is [System.Xml.XmlElement]) {
                        $rawDesc = $item.description.InnerText
                    } else {
                        $rawDesc = [string]$item.description
                    }
                }
                if (-not $rawDesc -and $item.summary) {
                    if ($item.summary -is [System.Xml.XmlElement]) {
                        $rawDesc = $item.summary.InnerText
                    } else {
                        $rawDesc = [string]$item.summary
                    }
                }
                if ($rawDesc) {
                    $desc = $rawDesc -replace '<[^>]+>', '' -replace '&nbsp;', ' ' -replace '\s+', ' '
                    $desc = $desc.Trim()
                    if ($desc.Length -gt 300) { $desc = $desc.Substring(0, 300) + "..." }
                }
                $newsItem.Summary = $desc
                $newsItem.Published = if ($published) { $published } else { Get-Date }

                $newsItems += $newsItem
            }
        } catch {
            Write-Log "Error fetching RSS from $($feed.Source): $_" "WARN"
        }
    }

    Write-Log "Fetched $($newsItems.Count) news items from RSS feeds"
    return $newsItems
}

#endregion

#region Scoring

function Score-Paper {
    param([Paper]$Paper, [string[]]$Keywords, [string[]]$RelatedTerms)
    $titleLower = $Paper.Title.ToLower()
    $abstractLower = $Paper.Abstract.ToLower()
    $score = 0; $matched = @{}
    foreach ($keyword in $Keywords) {
        if ($titleLower.Contains($keyword)) { $score += 3; $matched[$keyword] = $true }
        elseif ($abstractLower.Contains($keyword)) { $score += 2; $matched[$keyword] = $true }
    }
    foreach ($term in $RelatedTerms) {
        if (-not $matched.ContainsKey($term)) {
            if ($titleLower.Contains($term) -or $abstractLower.Contains($term)) { $score += 1; $matched[$term] = $true }
        }
    }
    $Paper.RelevanceScore = $score
    $Paper.MatchedKeywords = $matched.Keys
    return $score
}

function Score-NewsItem {
    param([NewsItem]$Item, [string[]]$Keywords, [string[]]$RelatedTerms)
    $titleLower = $Item.Title.ToLower()
    $summaryLower = $Item.Summary.ToLower()
    $score = 0; $matched = @{}
    foreach ($keyword in $Keywords) {
        if ($titleLower.Contains($keyword)) { $score += 3; $matched[$keyword] = $true }
        elseif ($summaryLower.Contains($keyword)) { $score += 2; $matched[$keyword] = $true }
    }
    foreach ($term in $RelatedTerms) {
        if (-not $matched.ContainsKey($term)) {
            if ($titleLower.Contains($term) -or $summaryLower.Contains($term)) { $score += 1; $matched[$term] = $true }
        }
    }
    $Item.RelevanceScore = $score
    $Item.MatchedKeywords = $matched.Keys
    return $score
}

#endregion

#region HTML Generation

function Generate-PaperCard {
    param([Paper]$Paper, [int]$Rank)

    $authorsDisplay = ($Paper.Authors | Select-Object -First 3) -join ", "
    if ($Paper.Authors.Count -gt 3) { $authorsDisplay += " et al." }

    $abstract = $Paper.Abstract
    if ($abstract.Length -gt 250) { $abstract = $abstract.Substring(0, 250) + "..." }

    # HTML-encode special characters
    $titleSafe = [System.Web.HttpUtility]::HtmlEncode($Paper.Title)
    $abstractSafe = [System.Web.HttpUtility]::HtmlEncode($abstract)
    $authorsSafe = [System.Web.HttpUtility]::HtmlEncode($authorsDisplay)

    $publishedStr = if ($Paper.Published) { $Paper.Published.ToString("MMM yyyy") } else { "" }

    # Build topic tags from matched keywords (top 3)
    $topicTags = ""
    $tagKeywords = $Paper.MatchedKeywords | Select-Object -First 3
    foreach ($kw in $tagKeywords) {
        $kwSafe = [System.Web.HttpUtility]::HtmlEncode((Get-Culture).TextInfo.ToTitleCase($kw))
        $topicTags += "            <span class=`"tag tag-topic`">$kwSafe</span>`n"
    }

    return @"

    <div class="card paper">
        <div class="rank">$Rank</div>
        <h3><a href="$($Paper.Url)" target="_blank">$titleSafe</a></h3>
        <div class="meta">
            <span>$authorsSafe</span>
            <span>$($Paper.Source)</span>
            <span>$publishedStr</span>
        </div>
        <p class="summary">$abstractSafe</p>
        <div class="tags">
            <span class="tag tag-paper">Paper</span>
$topicTags        </div>
    </div>
"@
}

function Generate-NewsCard {
    param([NewsItem]$Item, [int]$Rank)

    $titleSafe = [System.Web.HttpUtility]::HtmlEncode($Item.Title)
    $summarySafe = [System.Web.HttpUtility]::HtmlEncode($Item.Summary)
    $publishedStr = if ($Item.Published) { $Item.Published.ToString("MMM d, yyyy") } else { "" }

    $topicTags = ""
    $tagKeywords = $Item.MatchedKeywords | Select-Object -First 3
    foreach ($kw in $tagKeywords) {
        $kwSafe = [System.Web.HttpUtility]::HtmlEncode((Get-Culture).TextInfo.ToTitleCase($kw))
        $topicTags += "            <span class=`"tag tag-topic`">$kwSafe</span>`n"
    }

    return @"

    <div class="card news">
        <div class="rank">$Rank</div>
        <h3><a href="$($Item.Url)" target="_blank">$titleSafe</a></h3>
        <div class="meta"><span>$([System.Web.HttpUtility]::HtmlEncode($Item.Source))</span><span>$publishedStr</span></div>
        <p class="summary">$summarySafe</p>
        <div class="tags">
            <span class="tag tag-news">News</span>
$topicTags        </div>
    </div>
"@
}

function Update-WebsiteHtml {
    param(
        [string]$HtmlPath,
        [Paper[]]$Papers,
        [NewsItem[]]$NewsItems
    )

    $html = Get-Content -Path $HtmlPath -Raw -Encoding UTF8
    $monthYear = (Get-Date).ToString("MMMM yyyy")
    $monthShort = (Get-Date).ToString("MMMM")

    # Update title
    $html = $html -replace 'Spintronics Monthly Digest &mdash; \w+ \d{4}', "Spintronics Monthly Digest &mdash; $monthYear"

    # Update header period
    $html = $html -replace '<div class="period">\w+ \d{4}</div>', "<div class=`"period`">$monthYear</div>"

    # Update footer month
    $html = $html -replace 'Generated \w+ \d{4}', "Generated $monthYear"

    # Update paper count badge
    $html = $html -replace '(Papers\s*<span class="count-badge">)\d+(</span>)', "`${1}$($Papers.Count)`${2}"

    # Update news count badge
    $html = $html -replace '(News\s*<span class="count-badge">)\d+(</span>)', "`${1}$($NewsItems.Count)`${2}"

    # Generate papers section content
    $papersHtml = @"

    <div class="section-header">
        <h2>Top $($Papers.Count) Papers &amp; Discoveries &mdash; $monthYear</h2>
        <div class="line"></div>
    </div>
"@
    $rank = 0
    foreach ($paper in $Papers) {
        $rank++
        $papersHtml += Generate-PaperCard -Paper $paper -Rank $rank
    }
    $papersHtml += "`n"

    # Replace papers section (between markers)
    $papersPattern = '(?s)(<!-- ========== PAPERS SECTION ========== -->\s*<div id="papers" class="section[^"]*">).*?(</div>\s*<!-- ========== NEWS SECTION ========== -->)'
    $papersReplacement = "`${1}`n$papersHtml</div>`n`n`${2}" -replace '\$\{1\}', '$1' -replace '\$\{2\}', '$2'

    # Use regex replace for papers section
    $html = [regex]::Replace($html, $papersPattern, {
        param($m)
        "$($m.Groups[1].Value)`n$papersHtml</div>`n`n$($m.Groups[2].Value)"
    })

    # Generate news section content
    $newsHtml = @"

    <div class="section-header">
        <h2>Top $($NewsItems.Count) News &amp; Industry &mdash; $monthYear</h2>
        <div class="line"></div>
    </div>
"@
    $rank = 0
    foreach ($item in $NewsItems) {
        $rank++
        $newsHtml += Generate-NewsCard -Item $item -Rank $rank
    }
    $newsHtml += "`n"

    # Replace news section
    $newsPattern = '(?s)(<!-- ========== NEWS SECTION ========== -->\s*<div id="news" class="section">).*?(</div>\s*<!-- ========== CONFERENCES SECTION ========== -->)'
    $html = [regex]::Replace($html, $newsPattern, {
        param($m)
        "$($m.Groups[1].Value)`n$newsHtml</div>`n`n$($m.Groups[2].Value)"
    })

    return $html
}

#endregion

#region Main

# Fetch papers (30-day lookback for monthly digest)
Write-Log "--- Fetching papers ---"
$allPapers = @()
$allPapers += Fetch-ArxivPapers -Categories $arxivCategories -LookbackDays 30
$allPapers += Fetch-SemanticScholarPapers -Keywords $researchConfig.Keywords -LookbackDays 30 -ApiKey $ssApiKey

# Deduplicate
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

# Filter and sort - take top 10
$topPapers = $uniquePapers | Where-Object { $_.RelevanceScore -ge 2 } |
    Sort-Object -Property RelevanceScore -Descending |
    Select-Object -First 10

Write-Log "Top papers selected: $($topPapers.Count)"

# Fetch news
Write-Log "--- Fetching news ---"
$allNews = Fetch-RssNews -LookbackDays 30

# Score news
foreach ($item in $allNews) {
    Score-NewsItem -Item $item -Keywords $researchConfig.Keywords -RelatedTerms $researchConfig.RelatedTerms | Out-Null
}

# Sort by relevance and take top 10 (no minimum threshold — best available news)
$topNews = $allNews |
    Sort-Object -Property RelevanceScore -Descending |
    Select-Object -First 10

Write-Log "Top news selected: $($topNews.Count)"

# Test mode
if ($Test) {
    Write-Host ""
    Write-Host ("=" * 60)
    Write-Host "TEST MODE - Results (website will NOT be modified)"
    Write-Host ("=" * 60)

    Write-Host "`n--- TOP PAPERS ($($topPapers.Count)) ---"
    $i = 0
    foreach ($p in $topPapers) {
        $i++
        Write-Host "$i. [$($p.RelevanceScore)] $($p.Title)"
        Write-Host "   Source: $($p.Source) | $(($p.MatchedKeywords | Select-Object -First 3) -join ', ')"
    }

    Write-Host "`n--- TOP NEWS ($($topNews.Count)) ---"
    $i = 0
    foreach ($n in $topNews) {
        $i++
        Write-Host "$i. [$($n.RelevanceScore)] $($n.Title)"
        Write-Host "   Source: $($n.Source) | $(($n.MatchedKeywords | Select-Object -First 3) -join ', ')"
    }

    Write-Log "=== Monthly Website Update finished (test mode) ==="
    exit 0
}

# Check we have content
if ($topPapers.Count -eq 0 -and $topNews.Count -eq 0) {
    Write-Log "No papers or news found. Website not updated."
    Write-Log "=== Monthly Website Update finished (no content) ==="
    exit 0
}

# Update website
$indexPath = Join-Path $ScriptDir "..\index.html"
$indexPath = [System.IO.Path]::GetFullPath($indexPath)

if (-not (Test-Path $indexPath)) {
    Write-Log "index.html not found at $indexPath" "ERROR"
    exit 1
}

Write-Log "Updating website at $indexPath"

$updatedHtml = Update-WebsiteHtml -HtmlPath $indexPath -Papers $topPapers -NewsItems $topNews

# Write updated HTML
Set-Content -Path $indexPath -Value $updatedHtml -Encoding UTF8
Write-Log "Website updated successfully with $($topPapers.Count) papers and $($topNews.Count) news items"

# Deploy to GitHub Pages
$ghRepoUrl = if ($appConfig.githubRepoUrl) { $appConfig.githubRepoUrl } else { "" }
if ($ghRepoUrl -and $ghRepoUrl -ne "") {
    Write-Log "--- Deploying to GitHub Pages ---"
    $tempRepo = Join-Path ([System.IO.Path]::GetTempPath()) "spintronics-digest-deploy"

    try {
        # Clean up any previous temp clone
        if (Test-Path $tempRepo) {
            Remove-Item -Path $tempRepo -Recurse -Force
        }

        # Clone the repo
        Write-Log "Cloning $ghRepoUrl..."
        & git clone --depth 1 $ghRepoUrl $tempRepo 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }

        # Copy updated index.html
        Copy-Item -Path $indexPath -Destination (Join-Path $tempRepo "index.html") -Force

        # Commit and push
        $monthYear = (Get-Date).ToString("MMMM yyyy")
        Push-Location $tempRepo
        & git add index.html 2>&1 | Out-Null

        # Check if there are changes to commit
        $status = & git status --porcelain 2>&1
        if ($status) {
            & git commit -m "Update digest to $monthYear (automated)" 2>&1 | Out-Null
            & git push origin master 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Deployed to GitHub Pages successfully"
            } else {
                Write-Log "git push failed" "ERROR"
            }
        } else {
            Write-Log "No changes to deploy (index.html unchanged)"
        }
        Pop-Location

        # Clean up
        Remove-Item -Path $tempRepo -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log "Error deploying to GitHub: $_" "ERROR"
        Pop-Location -ErrorAction SilentlyContinue
    }
} else {
    Write-Log "No githubRepoUrl configured, skipping deployment"
}

Write-Log "=== Monthly Website Update finished (success) ==="
exit 0

#endregion
