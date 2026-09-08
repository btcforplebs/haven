package com.nostrvault.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.nostrvault.data.model.ArticleMeta
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.QuoteReference
import com.nostrvault.ui.theme.*

/**
 * Embedded quoted note card, rendered below note content when a note
 * references another via `nostr:note1...`, `nostr:nevent1...` or `nostr:naddr1...`.
 *
 * A quoted kind-30023 gets the article layout instead: its content is a whole
 * Markdown document, so three lines of it show `##` markup rather than the
 * article, and the headline, cover and summary live in tags anyway.
 *
 * Matches the iOS QuotedNoteView layout:
 * - 18dp avatar + author name (12sp bold) + timestamp (10sp)
 * - Content (13sp, secondary, 3-line max)
 * - First media thumbnail (if present, 180dp max height)
 * - TertiaryGroupedBg background, themed border, 8dp corner radius
 */
@Composable
fun QuotedNoteCard(
    note: FeedNote,
    profile: FeedProfile?,
    profiles: Map<String, FeedProfile> = emptyMap(),
    onClick: (String) -> Unit,
    // Opening an article on the note screen would show its Markdown source, so
    // callers that can reach the reader pass it here. Those that cannot fall
    // back to the note screen rather than making the card dead.
    onArticleClick: ((String) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current
    val isArticle = note.kind == ArticleMeta.KIND

    Surface(
        shape = RoundedCornerShape(8.dp),
        color = TertiaryGroupedBg,
        border = BorderStroke(
            // Embedded in a note, so it tracks NoteCard's OLED bump
            // rather than sitting fainter than the card it lives inside.
            if (LocalOledMode.current) 0.8.dp else 0.5.dp,
            colors.primary.copy(alpha = if (LocalOledMode.current) 0.18f else 0.12f),
        ),
        modifier = modifier
            .fillMaxWidth()
            .clickable {
                if (isArticle && onArticleClick != null) onArticleClick(note.id) else onClick(note.id)
            },
    ) {
        Column(
            modifier = Modifier.padding(10.dp),
        ) {
            // Author header
            Row(
                verticalAlignment = Alignment.CenterVertically,
            ) {
                AvatarImage(
                    url = profile?.pictureURL,
                    pubkey = note.pubkey,
                    size = 18.dp,
                    displayName = profile?.bestName,
                )

                Spacer(Modifier.width(6.dp))

                Text(
                    text = profile?.bestName ?: note.pubkey.take(8) + "...",
                    color = PrimaryText,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )

                Spacer(Modifier.width(6.dp))

                Text(
                    text = formatTimestamp(note.createdAt.time / 1000),
                    color = TertiaryText,
                    fontSize = 10.sp,
                )
            }

            if (isArticle) {
                Spacer(Modifier.height(6.dp))
                QuotedArticleBody(note = note)
            } else {
                // Content
                if (note.content.isNotBlank()) {
                    Spacer(Modifier.height(4.dp))
                    Text(
                        text = remember(note.content, profiles) {
                            NostrMentions.toPlainText(note.content, profiles)
                        },
                        color = SecondaryText,
                        fontSize = 13.sp,
                        lineHeight = 17.sp,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                // First media thumbnail
                if (note.mediaURLs.isNotEmpty()) {
                    val context = LocalContext.current
                    Spacer(Modifier.height(6.dp))
                    AsyncImage(
                        model = ImageRequest.Builder(context)
                            .data(note.mediaURLs.first())
                            .size(360) // Max 180dp at 2x density
                            .crossfade(100)
                            .build(),
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 180.dp)
                            .clip(RoundedCornerShape(6.dp))
                            .background(TertiaryGroupedBg),
                    )
                }
            }
        }
    }
}

/**
 * The body of a quoted NIP-23 article: cover thumbnail, an "Article" label, the
 * headline and the author's summary. Read from [ArticleMeta] — that is where a
 * long-form event actually keeps them — and never from the Markdown body.
 */
@Composable
private fun QuotedArticleBody(note: FeedNote) {
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    val meta = remember(note.id, note.tags, note.content) { ArticleMeta.from(note) }

    Row(verticalAlignment = Alignment.Top) {
        if (!meta.imageUrl.isNullOrBlank()) {
            AsyncImage(
                model = ImageRequest.Builder(context)
                    .data(meta.imageUrl)
                    .size(112) // 56dp at 2x density
                    .crossfade(100)
                    .build(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(56.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .background(TertiaryGroupedBg),
            )
            Spacer(Modifier.width(10.dp))
        }

        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "Article",
                color = colors.primary.copy(alpha = 0.8f),
                fontWeight = FontWeight.SemiBold,
                fontSize = 10.sp,
            )
            Spacer(Modifier.height(3.dp))
            Text(
                text = meta.title,
                color = PrimaryText,
                fontWeight = FontWeight.SemiBold,
                fontSize = 13.sp,
                lineHeight = 17.sp,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (!meta.summary.isNullOrBlank()) {
                Spacer(Modifier.height(3.dp))
                Text(
                    text = meta.summary,
                    color = SecondaryText,
                    fontSize = 12.sp,
                    lineHeight = 16.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/**
 * Placeholder for a quoted event that hasn't been fetched yet.
 *
 * An unresolved `naddr:` coordinate is deliberately not tappable: it is not an
 * event id, so handing it to the note screen opens a route that can never load.
 * Once it resolves this is replaced by the card, which is tappable.
 */
@Composable
fun QuotedNotePlaceholder(
    identifier: String,
    onClick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current
    val isCoordinate = QuoteReference.isCoordinate(identifier)

    Surface(
        shape = RoundedCornerShape(8.dp),
        color = TertiaryGroupedBg,
        border = BorderStroke(
            // Embedded in a note, so it tracks NoteCard's OLED bump
            // rather than sitting fainter than the card it lives inside.
            if (LocalOledMode.current) 0.8.dp else 0.5.dp,
            colors.primary.copy(alpha = if (LocalOledMode.current) 0.18f else 0.12f),
        ),
        modifier = modifier
            .fillMaxWidth()
            .then(if (isCoordinate) Modifier else Modifier.clickable { onClick(identifier) }),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(10.dp),
        ) {
            Icon(
                imageVector = NostrVaultIcons.Feed,
                contentDescription = null,
                tint = TertiaryText,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text = if (isCoordinate) "Loading article..." else "Loading quoted note...",
                color = TertiaryText,
                fontSize = 12.sp,
            )
        }
    }
}
