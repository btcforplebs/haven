package com.nostrvault.data.model

import kotlinx.serialization.Serializable

@Serializable
data class StarterPacksData(
    val packs: List<StarterPack>,
)

@Serializable
data class StarterPack(
    val id: String,
    val name: String,
    val description: String,
    val accounts: List<RecommendedAccount>,
)

@Serializable
data class RecommendedAccount(
    val npub: String,
    val name: String,
    val about: String,
    val picture: String,
)
