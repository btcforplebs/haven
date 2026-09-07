package com.nostrvault.data.model

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecipeTopicsTest {

    private fun t(vararg topics: String) = topics.map { listOf("t", it) }

    @Test fun `base topics match`() {
        assertTrue(RecipeTopics.matches(t("zapcooking")))
        assertTrue(RecipeTopics.matches(t("nostrcooking")))
    }

    @Test fun `category tags match`() {
        // zap.cooking files recipes under zapcooking-<category>; a recipe
        // carrying only a category tag is still a recipe.
        assertTrue(RecipeTopics.matches(t("zapcooking-dessert")))
        assertTrue(RecipeTopics.matches(t("food", "zapcooking-beef")))
    }

    @Test fun `case is ignored`() {
        assertTrue(RecipeTopics.matches(t("ZapCooking")))
        assertTrue(RecipeTopics.matches(t("ZAPCOOKING-Dessert")))
    }

    @Test fun `unrelated topics do not match`() {
        assertFalse(RecipeTopics.matches(t("cooking")))
        assertFalse(RecipeTopics.matches(t("food", "recipe")))
        assertFalse(RecipeTopics.matches(emptyList()))
    }

    @Test fun `only t tags count`() {
        // A title that happens to read "zapcooking" is not a topic.
        assertFalse(RecipeTopics.matches(listOf(listOf("title", "zapcooking"))))
        assertFalse(RecipeTopics.matches(listOf(listOf("t"))))
    }
}
