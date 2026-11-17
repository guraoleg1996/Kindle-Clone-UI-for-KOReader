# Kindle Clone UI for KOReader

<img width="1376" height="768" alt="Gemini_Generated_Image_qirgqcqirgqcqirg" src="https://github.com/user-attachments/assets/e8e6065b-d0ff-4929-a40d-fb626f305111" />

<br>
<br>

Makes KOReader look and work like a Kindle. Both list and grid view and in-book features like bookmarks etc. 

It's not a 1:1 replica, just as close as I could make it. This fork was created for personal use—to share with friends and loved ones—as well as for anyone who wants to make their KOReader look a bit like a Kindle.

> **Future Plans:** The ultimate goal is to completely phase out all default KOReader settings menus and native UI elements, replacing them with a custom interface seamlessly integrated into the existing layout to match the Kindle experience even closer.

- **Needs:** KOReader v2026.07 or later.
  - And also a one-time initial loading wait time if you have a large library.

- **Install:** copy the whole `kindle-clone-ui.koplugin` folder into `koreader/plugins/`


**First launch:** it asks two setup questions, then reads your book details (let the progress bar finish, it might take a while. **This is to help it later be fast at switching pages/folders.** If you have a big book library, just let it run for 5-15 minutes, or longer sorry, but it will only do this once on initial setup, any new books added after initial setup will automatically be scanned later too), and then it restarts KOReader once setup is finished.


**You can access the default KOReader settings menu by clicking the cogwheel "All Settings".** 
For example, to enable or disable plugins, go into `All Settings > Tools > More tools > Plugin management`.
