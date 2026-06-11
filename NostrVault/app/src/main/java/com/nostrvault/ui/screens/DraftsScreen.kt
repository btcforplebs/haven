package com.nostrvault.ui.screens

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import com.nostrvault.data.model.Draft
import com.nostrvault.service.DraftService
import com.nostrvault.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import java.text.SimpleDateFormat
import java.util.*
import javax.inject.Inject

@HiltViewModel
class DraftsViewModel @Inject constructor(
    private val draftService: DraftService,
) : ViewModel() {
    val drafts = draftService.drafts

    fun deleteDraft(draftId: String) {
        draftService.deleteDraft(draftId)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DraftsScreen(
    onResumeDraft: (draftId: String, content: String, replyToId: String?, quoteToId: String?) -> Unit,
    onBack: () -> Unit,
    viewModel: DraftsViewModel = hiltViewModel(),
) {
    val drafts by viewModel.drafts.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Drafts", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(NostrVaultIcons.Back, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = WindowBackground,
                    titleContentColor = PrimaryText,
                    navigationIconContentColor = PrimaryText,
                ),
            )
        },
        containerColor = WindowBackground,
    ) { padding ->
        if (drafts.isEmpty()) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(
                        imageVector = NostrVaultIcons.Edit,
                        contentDescription = null,
                        tint = TertiaryText,
                        modifier = Modifier.size(48.dp),
                    )
                    Spacer(Modifier.height(12.dp))
                    Text(
                        text = "No drafts",
                        color = SecondaryText,
                        fontSize = 16.sp,
                    )
                    Text(
                        text = "Drafts are saved automatically as you type",
                        color = TertiaryText,
                        fontSize = 13.sp,
                    )
                }
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(
                    items = drafts,
                    key = { it.id },
                ) { draft ->
                    val dismissState = rememberSwipeToDismissBoxState(
                        confirmValueChange = { value ->
                            if (value != SwipeToDismissBoxValue.Settled) {
                                viewModel.deleteDraft(draft.id)
                                true
                            } else false
                        },
                    )

                    SwipeToDismissBox(
                        state = dismissState,
                        backgroundContent = {
                            val color by animateColorAsState(
                                if (dismissState.dismissDirection == SwipeToDismissBoxValue.EndToStart)
                                    ErrorRed.copy(alpha = 0.9f)
                                else ErrorRed.copy(alpha = 0.3f),
                                label = "dismiss-bg",
                            )
                            Box(
                                contentAlignment = Alignment.CenterEnd,
                                modifier = Modifier
                                    .fillMaxSize()
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(color)
                                    .padding(end = 20.dp),
                            ) {
                                Icon(
                                    imageVector = NostrVaultIcons.Delete,
                                    contentDescription = "Delete",
                                    tint = PrimaryText,
                                )
                            }
                        },
                        enableDismissFromStartToEnd = false,
                    ) {
                        DraftCard(
                            draft = draft,
                            onClick = {
                                onResumeDraft(
                                    draft.id,
                                    draft.content,
                                    draft.replyToId,
                                    draft.quoteId,
                                )
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun DraftCard(
    draft: Draft,
    onClick: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val dateFormatter = remember {
        SimpleDateFormat("MMM d, h:mm a", Locale.getDefault())
    }

    Surface(
        shape = RoundedCornerShape(12.dp),
        color = SecondaryGroupedBg,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
        ) {
            // Header row: type badge + timestamp
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                // Type indicator
                if (draft.isReply) {
                    Surface(
                        shape = RoundedCornerShape(6.dp),
                        color = colors.primary.copy(alpha = 0.15f),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                        ) {
                            Icon(
                                imageVector = NostrVaultIcons.Reply,
                                contentDescription = null,
                                tint = colors.primary,
                                modifier = Modifier.size(12.dp),
                            )
                            Spacer(Modifier.width(4.dp))
                            Text(
                                text = "Reply",
                                color = colors.primary,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                        }
                    }
                    Spacer(Modifier.width(8.dp))
                } else if (draft.isQuote) {
                    Surface(
                        shape = RoundedCornerShape(6.dp),
                        color = colors.primary.copy(alpha = 0.15f),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                        ) {
                            Icon(
                                imageVector = NostrVaultIcons.Quote,
                                contentDescription = null,
                                tint = colors.primary,
                                modifier = Modifier.size(12.dp),
                            )
                            Spacer(Modifier.width(4.dp))
                            Text(
                                text = "Quote",
                                color = colors.primary,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                        }
                    }
                    Spacer(Modifier.width(8.dp))
                }

                Spacer(Modifier.weight(1f))

                Text(
                    text = dateFormatter.format(Date(draft.updatedAt)),
                    color = TertiaryText,
                    fontSize = 12.sp,
                )
            }

            Spacer(Modifier.height(8.dp))

            // Content preview
            Text(
                text = draft.preview.ifEmpty { "(empty draft)" },
                color = PrimaryText,
                fontSize = 15.sp,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )

            Spacer(Modifier.height(6.dp))

            // Character count
            Text(
                text = "${draft.content.length} characters",
                color = TertiaryText,
                fontSize = 12.sp,
            )
        }
    }
}
