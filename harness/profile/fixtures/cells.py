# A script with `# %%` cells -- the Jupytext/VS Code/Spyder convention.
# `jsonyter-script-mode' runs these against a kernel and shows the output
# in overlays, so the file on disk never changes.

# %%
print("first cell")

# %%
6 * 7

# %%
plot_something()

# %%
raise ValueError("boom")
