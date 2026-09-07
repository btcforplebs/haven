package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Date

class ArticleMetaTest {

    private fun article(
        tags: List<List<String>>,
        content: String = "# Heading\n\nBody",
        createdAt: Long = 1_700_000_000L,
    ) = FeedNote.fromEvent(
        id = "a".repeat(64),
        pubkey = "b".repeat(64),
        content = content,
        tags = tags,
        createdAt = createdAt,
        kind = ArticleMeta.KIND,
    )

    @Test fun `reads the header off the tags`() {
        val meta = ArticleMeta.from(article(listOf(
            listOf("title", "On Vaults"),
            listOf("summary", "Why you keep your own"),
            listOf("image", "https://example.com/cover.jpg"),
            listOf("d", "on-vaults"),
        )))
        assertEquals("On Vaults", meta.title)
        assertEquals("Why you keep your own", meta.summary)
        assertEquals("https://example.com/cover.jpg", meta.imageUrl)
        assertEquals("on-vaults", meta.identifier)
    }

    @Test fun `published_at wins over the event timestamp`() {
        // The point of the field: an edit gives the event a new created_at, and
        // ordering by that alone floats old articles to the top of the list
        // every time someone fixes a typo.
        val meta = ArticleMeta.from(article(
            tags = listOf(listOf("title", "T"), listOf("published_at", "1600000000")),
            createdAt = 1_700_000_000L,
        ))
        assertEquals(Date(1_600_000_000L * 1000), meta.publishedAt)
    }

    @Test fun `falls back to the event timestamp when published_at is absent or junk`() {
        val expected = Date(1_700_000_000L * 1000)
        assertEquals(expected, ArticleMeta.from(article(listOf(listOf("title", "T")))).publishedAt)
        assertEquals(
            expected,
            ArticleMeta.from(article(listOf(listOf("title", "T"), listOf("published_at", "soon")))).publishedAt,
        )
    }

    @Test fun `an untitled article uses its first line rather than an empty row`() {
        val meta = ArticleMeta.from(article(tags = emptyList(), content = "\n\n# The Quiet Part\n\nrest"))
        assertEquals("The Quiet Part", meta.title)
        assertNull(meta.summary)
    }

    @Test fun `blank tag values count as absent`() {
        val meta = ArticleMeta.from(article(listOf(
            listOf("title", "  "),
            listOf("summary", ""),
            listOf("image", ""),
        ), content = "Plain opening line"))
        assertEquals("Plain opening line", meta.title)
        assertNull(meta.summary)
        assertNull(meta.imageUrl)
    }
}
