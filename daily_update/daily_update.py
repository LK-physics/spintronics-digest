#!/usr/bin/env python3
"""
Daily Paper Update Agent
Searches arXiv and Semantic Scholar for papers matching research interests
and sends an email digest.
"""

import argparse
import json
import re
import smtplib
import sys
from datetime import datetime, timedelta, timezone
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from pathlib import Path
from typing import Optional
from urllib.parse import urlencode

import feedparser
import requests
from dateutil import parser as date_parser


class ConfigLoader:
    """Parse research interests config file to extract keywords."""

    def __init__(self, config_path: str):
        self.config_path = Path(config_path)
        self.keywords: list[str] = []
        self.related_terms: list[str] = []
        self._parse_config()

    def _parse_config(self):
        """Parse the markdown config file and extract keywords."""
        if not self.config_path.exists():
            raise FileNotFoundError(f"Config file not found: {self.config_path}")

        content = self.config_path.read_text(encoding='utf-8')

        # Extract keywords from ### Keywords sections
        keyword_sections = re.findall(
            r'### Keywords\n(.*?)(?=\n###|\n---|\n## |$)',
            content,
            re.DOTALL
        )
        for section in keyword_sections:
            keywords = re.findall(r'^- (.+)$', section, re.MULTILINE)
            self.keywords.extend([k.strip().lower() for k in keywords])

        # Extract related terms from ### Related Terms sections
        related_sections = re.findall(
            r'### Related Terms\n(.*?)(?=\n###|\n---|\n## |$)',
            content,
            re.DOTALL
        )
        for section in related_sections:
            terms = re.findall(r'^- (.+)$', section, re.MULTILINE)
            self.related_terms.extend([t.strip().lower() for t in terms])

        # Remove duplicates while preserving order
        self.keywords = list(dict.fromkeys(self.keywords))
        self.related_terms = list(dict.fromkeys(self.related_terms))

        print(f"Loaded {len(self.keywords)} keywords and {len(self.related_terms)} related terms")


class Paper:
    """Represents a research paper."""

    def __init__(
        self,
        title: str,
        authors: list[str],
        abstract: str,
        url: str,
        source: str,
        published: Optional[datetime] = None,
        arxiv_id: Optional[str] = None
    ):
        self.title = title
        self.authors = authors
        self.abstract = abstract
        self.url = url
        self.source = source
        self.published = published
        self.arxiv_id = arxiv_id
        self.relevance_score = 0
        self.matched_keywords: list[str] = []

    def __repr__(self):
        return f"Paper({self.title[:50]}..., score={self.relevance_score})"


class ArxivFetcher:
    """Fetch papers from arXiv API."""

    BASE_URL = "http://export.arxiv.org/api/query"

    def __init__(self, categories: list[str], lookback_hours: int = 48):
        self.categories = categories
        self.lookback_hours = lookback_hours

    def fetch(self) -> list[Paper]:
        """Fetch recent papers from arXiv."""
        papers = []

        # Build category query
        cat_query = " OR ".join([f"cat:{cat}" for cat in self.categories])

        params = {
            "search_query": cat_query,
            "start": 0,
            "max_results": 200,
            "sortBy": "submittedDate",
            "sortOrder": "descending"
        }

        url = f"{self.BASE_URL}?{urlencode(params)}"
        print(f"Fetching arXiv papers...")

        try:
            feed = feedparser.parse(url)

            if feed.bozo:
                print(f"Warning: Feed parsing issue - {feed.bozo_exception}")

            cutoff_time = datetime.now(timezone.utc) - timedelta(hours=self.lookback_hours)

            for entry in feed.entries:
                # Parse publication date
                published = None
                if hasattr(entry, 'published'):
                    try:
                        published = date_parser.parse(entry.published)
                        if published.tzinfo is None:
                            published = published.replace(tzinfo=timezone.utc)
                    except Exception:
                        pass

                # Filter by date
                if published and published < cutoff_time:
                    continue

                # Extract arXiv ID
                arxiv_id = None
                if hasattr(entry, 'id'):
                    match = re.search(r'arxiv.org/abs/(.+)$', entry.id)
                    if match:
                        arxiv_id = match.group(1)

                # Extract authors
                authors = []
                if hasattr(entry, 'authors'):
                    authors = [a.get('name', '') for a in entry.authors]

                paper = Paper(
                    title=entry.title.replace('\n', ' ').strip(),
                    authors=authors,
                    abstract=entry.summary.replace('\n', ' ').strip() if hasattr(entry, 'summary') else '',
                    url=entry.link if hasattr(entry, 'link') else entry.id,
                    source="arXiv",
                    published=published,
                    arxiv_id=arxiv_id
                )
                papers.append(paper)

            print(f"Fetched {len(papers)} papers from arXiv")

        except Exception as e:
            print(f"Error fetching from arXiv: {e}")

        return papers


class SemanticScholarFetcher:
    """Fetch papers from Semantic Scholar API."""

    BASE_URL = "https://api.semanticscholar.org/graph/v1/paper/search"

    def __init__(self, keywords: list[str], lookback_hours: int = 48):
        self.keywords = keywords[:5]  # Use top 5 keywords to avoid too many requests
        self.lookback_hours = lookback_hours

    def fetch(self) -> list[Paper]:
        """Fetch recent papers from Semantic Scholar."""
        papers = []
        seen_ids = set()

        # Calculate date range
        end_date = datetime.now()
        start_date = end_date - timedelta(hours=self.lookback_hours)
        date_range = f"{start_date.strftime('%Y-%m-%d')}:{end_date.strftime('%Y-%m-%d')}"

        print(f"Fetching Semantic Scholar papers...")

        for keyword in self.keywords:
            try:
                params = {
                    "query": keyword,
                    "limit": 50,
                    "fields": "title,authors,abstract,url,publicationDate,externalIds",
                    "publicationDateOrYear": date_range
                }

                response = requests.get(
                    self.BASE_URL,
                    params=params,
                    headers={"Accept": "application/json"},
                    timeout=30
                )

                if response.status_code == 429:
                    print(f"Rate limited by Semantic Scholar, skipping remaining keywords")
                    break

                if response.status_code != 200:
                    print(f"Semantic Scholar returned status {response.status_code} for '{keyword}'")
                    continue

                data = response.json()

                for item in data.get("data", []):
                    paper_id = item.get("paperId", "")
                    if paper_id in seen_ids:
                        continue
                    seen_ids.add(paper_id)

                    # Parse publication date
                    published = None
                    pub_date = item.get("publicationDate")
                    if pub_date:
                        try:
                            published = date_parser.parse(pub_date)
                            if published.tzinfo is None:
                                published = published.replace(tzinfo=timezone.utc)
                        except Exception:
                            pass

                    # Extract authors
                    authors = [a.get("name", "") for a in item.get("authors", [])]

                    # Get URL
                    url = item.get("url", "")
                    external_ids = item.get("externalIds", {})
                    if external_ids.get("ArXiv"):
                        url = f"https://arxiv.org/abs/{external_ids['ArXiv']}"
                    elif external_ids.get("DOI"):
                        url = f"https://doi.org/{external_ids['DOI']}"

                    paper = Paper(
                        title=item.get("title", "").strip(),
                        authors=authors,
                        abstract=item.get("abstract", "") or "",
                        url=url,
                        source="Semantic Scholar",
                        published=published
                    )
                    papers.append(paper)

            except requests.RequestException as e:
                print(f"Error fetching '{keyword}' from Semantic Scholar: {e}")
            except Exception as e:
                print(f"Unexpected error for '{keyword}': {e}")

        print(f"Fetched {len(papers)} papers from Semantic Scholar")
        return papers


class RelevanceScorer:
    """Score papers based on keyword matches."""

    def __init__(self, keywords: list[str], related_terms: list[str]):
        self.keywords = [k.lower() for k in keywords]
        self.related_terms = [t.lower() for t in related_terms]

    def score(self, paper: Paper) -> int:
        """
        Score a paper based on keyword matches.
        +3 points: Primary keyword in title
        +2 points: Primary keyword in abstract
        +1 point: Related term in title/abstract
        """
        title_lower = paper.title.lower()
        abstract_lower = paper.abstract.lower()

        score = 0
        matched = set()

        # Check primary keywords
        for keyword in self.keywords:
            if keyword in title_lower:
                score += 3
                matched.add(keyword)
            elif keyword in abstract_lower:
                score += 2
                matched.add(keyword)

        # Check related terms
        for term in self.related_terms:
            if term not in matched:  # Don't double-count
                if term in title_lower or term in abstract_lower:
                    score += 1
                    matched.add(term)

        paper.relevance_score = score
        paper.matched_keywords = list(matched)
        return score


class EmailFormatter:
    """Format papers into an HTML email."""

    def __init__(self, max_papers: int = 15):
        self.max_papers = max_papers

    def format(self, papers: list[Paper], date_str: str) -> tuple[str, str]:
        """
        Format papers into HTML email.
        Returns (subject, html_body).
        """
        subject = f"Daily Paper Update - {date_str}"

        html_parts = [
            """<!DOCTYPE html>
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
""",
            f"<h1>Daily Paper Update - {date_str}</h1>",
            f"<p>Found <strong>{len(papers)}</strong> relevant papers from the last 48 hours.</p>"
        ]

        for i, paper in enumerate(papers[:self.max_papers], 1):
            authors_str = ", ".join(paper.authors[:5])
            if len(paper.authors) > 5:
                authors_str += f" et al. ({len(paper.authors)} authors)"

            # Truncate abstract
            abstract = paper.abstract[:400]
            if len(paper.abstract) > 400:
                abstract += "..."

            keywords_str = ", ".join(paper.matched_keywords[:5]) if paper.matched_keywords else "General match"

            html_parts.append(f"""
<div class="paper">
    <div class="paper-title">
        {i}. <a href="{paper.url}" target="_blank">{paper.title}</a>
        <span class="score">Score: {paper.relevance_score}</span>
    </div>
    <div class="paper-meta">
        <strong>Authors:</strong> {authors_str}<br>
        <strong>Source:</strong> {paper.source}
        {f' | <strong>Published:</strong> {paper.published.strftime("%Y-%m-%d")}' if paper.published else ''}
    </div>
    <div class="paper-keywords">
        <strong>Matched:</strong> {keywords_str}
    </div>
    <div class="paper-abstract">{abstract}</div>
</div>
""")

        html_parts.append(f"""
<div class="footer">
    <p>This digest was automatically generated by the Daily Paper Update Agent.<br>
    Research interests configured in: research_interests_agent_config.md</p>
</div>
</body>
</html>
""")

        return subject, "".join(html_parts)


class EmailSender:
    """Send email via SMTP."""

    def __init__(
        self,
        smtp_server: str,
        smtp_port: int,
        sender_email: str,
        sender_password: str,
        recipient_email: str
    ):
        self.smtp_server = smtp_server
        self.smtp_port = smtp_port
        self.sender_email = sender_email
        self.sender_password = sender_password
        self.recipient_email = recipient_email

    def send(self, subject: str, html_body: str) -> bool:
        """Send an HTML email. Returns True on success."""
        msg = MIMEMultipart('alternative')
        msg['Subject'] = subject
        msg['From'] = self.sender_email
        msg['To'] = self.recipient_email

        # Create plain text version
        plain_text = re.sub(r'<[^>]+>', '', html_body)
        plain_text = re.sub(r'\s+', ' ', plain_text).strip()

        msg.attach(MIMEText(plain_text, 'plain'))
        msg.attach(MIMEText(html_body, 'html'))

        try:
            with smtplib.SMTP(self.smtp_server, self.smtp_port) as server:
                server.starttls()
                server.login(self.sender_email, self.sender_password)
                server.sendmail(self.sender_email, self.recipient_email, msg.as_string())
            print(f"Email sent successfully to {self.recipient_email}")
            return True
        except smtplib.SMTPAuthenticationError:
            print("SMTP Authentication failed. Check your email credentials.")
            print("For Gmail, make sure you're using an App Password.")
            return False
        except Exception as e:
            print(f"Error sending email: {e}")
            return False


def load_config(config_path: str) -> dict:
    """Load JSON configuration file."""
    path = Path(config_path)
    if not path.exists():
        raise FileNotFoundError(f"Config file not found: {config_path}")

    with open(path, 'r', encoding='utf-8') as f:
        return json.load(f)


def main():
    parser = argparse.ArgumentParser(
        description="Daily Paper Update Agent - Search for relevant papers and send email digest"
    )
    parser.add_argument(
        "--config",
        default="config.json",
        help="Path to configuration file (default: config.json)"
    )
    parser.add_argument(
        "--test",
        action="store_true",
        help="Test mode: fetch papers and display results without sending email"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Dry run: fetch papers and format email but don't send"
    )
    args = parser.parse_args()

    # Determine script directory for relative paths
    script_dir = Path(__file__).parent.resolve()

    # Load configuration
    config_path = Path(args.config)
    if not config_path.is_absolute():
        config_path = script_dir / config_path

    print(f"Loading configuration from {config_path}")
    config = load_config(str(config_path))

    # Load research interests
    research_config_path = config.get("research_config_path", "../research_interests_agent_config.md")
    if not Path(research_config_path).is_absolute():
        research_config_path = script_dir / research_config_path

    print(f"Loading research interests from {research_config_path}")
    research_config = ConfigLoader(str(research_config_path))

    # Initialize fetchers
    arxiv_categories = config.get("arxiv_categories", ["cond-mat.mes-hall", "cond-mat.mtrl-sci", "physics.app-ph"])
    lookback_hours = config.get("lookback_hours", 48)

    arxiv_fetcher = ArxivFetcher(arxiv_categories, lookback_hours)
    semantic_fetcher = SemanticScholarFetcher(research_config.keywords, lookback_hours)

    # Fetch papers
    all_papers: list[Paper] = []
    all_papers.extend(arxiv_fetcher.fetch())
    all_papers.extend(semantic_fetcher.fetch())

    # Remove duplicates based on title similarity
    seen_titles = set()
    unique_papers = []
    for paper in all_papers:
        # Normalize title for comparison
        normalized = re.sub(r'[^\w\s]', '', paper.title.lower())
        normalized = ' '.join(normalized.split())

        if normalized not in seen_titles:
            seen_titles.add(normalized)
            unique_papers.append(paper)

    print(f"Total unique papers: {len(unique_papers)}")

    # Score papers
    scorer = RelevanceScorer(research_config.keywords, research_config.related_terms)
    for paper in unique_papers:
        scorer.score(paper)

    # Filter by minimum score
    min_score = config.get("min_relevance_score", 2)
    relevant_papers = [p for p in unique_papers if p.relevance_score >= min_score]

    # Sort by relevance score (descending)
    relevant_papers.sort(key=lambda p: p.relevance_score, reverse=True)

    print(f"Papers with relevance score >= {min_score}: {len(relevant_papers)}")

    if args.test:
        print("\n" + "="*60)
        print("TEST MODE - Top papers found:")
        print("="*60)
        for i, paper in enumerate(relevant_papers[:15], 1):
            print(f"\n{i}. [{paper.relevance_score}] {paper.title}")
            print(f"   Authors: {', '.join(paper.authors[:3])}")
            print(f"   Keywords: {', '.join(paper.matched_keywords[:5])}")
            print(f"   URL: {paper.url}")
        return 0

    if not relevant_papers:
        print("No relevant papers found for today. Skipping email.")
        return 0

    # Format email
    max_papers = config.get("max_papers", 15)
    formatter = EmailFormatter(max_papers)
    date_str = datetime.now().strftime("%B %d, %Y")
    subject, html_body = formatter.format(relevant_papers, date_str)

    if args.dry_run:
        print("\n" + "="*60)
        print("DRY RUN - Email would be sent:")
        print("="*60)
        print(f"Subject: {subject}")
        print(f"Papers: {len(relevant_papers[:max_papers])}")
        print("\nTo actually send the email, run without --dry-run flag.")
        return 0

    # Send email
    email_config = config.get("email", {})

    # Validate email configuration
    if email_config.get("sender_email", "").startswith("YOUR_"):
        print("ERROR: Please configure your email settings in config.json")
        print("See README.md for setup instructions.")
        return 1

    sender = EmailSender(
        smtp_server=email_config.get("smtp_server", "smtp.gmail.com"),
        smtp_port=email_config.get("smtp_port", 587),
        sender_email=email_config.get("sender_email", ""),
        sender_password=email_config.get("sender_password", ""),
        recipient_email=email_config.get("recipient_email", "")
    )

    if sender.send(subject, html_body):
        print("Daily paper update completed successfully!")
        return 0
    else:
        print("Failed to send email.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
