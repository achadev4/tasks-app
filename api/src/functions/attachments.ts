import { app } from "@azure/functions";
import { attachmentsHandler } from "../handlers/attachmentsHttp.js";

app.http("taskAttachments", {
  methods: ["POST", "OPTIONS"],
  route: "tasks/{taskId}/attachments",
  authLevel: "anonymous",
  handler: attachmentsHandler,
});
